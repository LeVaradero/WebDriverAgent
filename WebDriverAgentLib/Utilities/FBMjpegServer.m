/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBMjpegServer.h"

#import <mach/mach_time.h>
@import UniformTypeIdentifiers;

#import "GCDAsyncSocket.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBScreenshot.h"
#import "FBImageProcessor.h"
#import "FBImageUtils.h"
#import "XCUIScreen.h"

// Ajouts pour FBH264Server (cf. plus bas) : l'encodeur materiel et le
// decodage du JPEG rendu par la capture.
@import UIKit;
@import VideoToolbox;


static const NSUInteger MAX_FPS = 60;
static const NSTimeInterval FRAME_TIMEOUT = 1.;
static const NSTimeInterval FAILURE_BACKOFF_MIN = 1.0;
static const NSTimeInterval FAILURE_BACKOFF_MAX = 10.0;

static NSString *const SERVER_NAME = @"WDA MJPEG Server";
static const char *QUEUE_NAME = "JPEG Screenshots Provider Queue";

static NSUInteger FBNormalizedMjpegFramerate(NSUInteger framerate)
{
  return (0 == framerate || framerate > MAX_FPS) ? MAX_FPS : framerate;
}


@interface FBMjpegServer()

@property (nonatomic, readonly) dispatch_queue_t backgroundQueue;
@property (nonatomic, readonly) NSMutableArray<GCDAsyncSocket *> *listeningClients;
@property (nonatomic, readonly) FBImageProcessor *imageProcessor;
@property (nonatomic, readonly) long long mainScreenID;
@property (nonatomic, assign) NSUInteger consecutiveScreenshotFailures;
@property (atomic, assign) BOOL isStreaming;
@property (nonatomic, assign) NSUInteger sentFramesCount;
@property (nonatomic, assign) NSUInteger sentBytesCount;

@end


@implementation FBMjpegServer

- (instancetype)init
{
  if ((self = [super init])) {
    _consecutiveScreenshotFailures = 0;
    _isStreaming = YES;
    _sentFramesCount = 0;
    _sentBytesCount = 0;
    _listeningClients = [NSMutableArray array];
    _imageProcessor = [[FBImageProcessor alloc] init];
    _mainScreenID = [XCUIScreen.mainScreen displayID];
    dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    _backgroundQueue = dispatch_queue_create(QUEUE_NAME, queueAttributes);
    __weak typeof(self) weakSelf = self;
    dispatch_async(_backgroundQueue, ^{
      [weakSelf streamScreenshot];
    });
  }
  return self;
}

- (void)scheduleNextScreenshotWithInterval:(uint64_t)timerInterval timeStarted:(uint64_t)timeStarted
{
  if (!self.isStreaming) {
    return;
  }
  uint64_t timeElapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - timeStarted;
  int64_t nextTickDelta = (int64_t)timerInterval - (int64_t)timeElapsed;
  __weak typeof(self) weakSelf = self;
  if (nextTickDelta > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nextTickDelta), self.backgroundQueue, ^{
      [weakSelf streamScreenshot];
    });
  } else {
    // Try to do our best to keep the FPS at a decent level
    dispatch_async(self.backgroundQueue, ^{
      [weakSelf streamScreenshot];
    });
  }
}

- (void)streamScreenshot
{
  if (!self.isStreaming) {
    return;
  }
  NSUInteger framerate = FBNormalizedMjpegFramerate(FBConfiguration.mjpegServerFramerate);
  uint64_t timerInterval = (uint64_t)(1.0 / (double)framerate * NSEC_PER_SEC);
  uint64_t timeStarted = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  @synchronized (self.listeningClients) {
    if (0 == self.listeningClients.count) {
      [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
      return;
    }
  }

  NSError *error;
  CGFloat compressionQuality = MAX(FBMinCompressionQuality,
                                   MIN(FBMaxCompressionQuality, (double)FBConfiguration.mjpegServerScreenshotQuality / 100.0));
  NSData *screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:self.mainScreenID
                                                           compressionQuality:compressionQuality
                                                                          uti:UTTypeJPEG
                                                                      timeout:FRAME_TIMEOUT
                                                                        error:&error];
  if (nil == screenshotData) {
    [FBLogger logFmt:@"%@", error.description];
    self.consecutiveScreenshotFailures++;
    NSTimeInterval backoffSeconds = MIN(FAILURE_BACKOFF_MAX,
                                        FAILURE_BACKOFF_MIN * (1 << MIN(self.consecutiveScreenshotFailures, 4)));
    uint64_t backoffInterval = (uint64_t)(backoffSeconds * NSEC_PER_SEC);
    [self scheduleNextScreenshotWithInterval:backoffInterval timeStarted:timeStarted];
    return;
  }

  self.consecutiveScreenshotFailures = 0;

  CGFloat scalingFactor = FBConfiguration.mjpegScalingFactor / 100.0;
  __weak typeof(self) weakSelf = self;
  [self.imageProcessor submitImageData:screenshotData
                         scalingFactor:scalingFactor
                     completionHandler:^(NSData * _Nonnull scaled) {
    [weakSelf sendScreenshot:scaled];
  }];

  [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
}

- (void)sendScreenshot:(NSData *)screenshotData {
  if (!self.isStreaming) {
    return;
  }
  NSString *chunkHeader = [NSString stringWithFormat:@"--BoundaryString\r\nContent-type: image/jpeg\r\nContent-Length: %@\r\n\r\n", @(screenshotData.length)];
  NSMutableData *chunk = [[chunkHeader dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [chunk appendData:screenshotData];
  [chunk appendData:(id)[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  @synchronized (self.listeningClients) {
    if (!self.isStreaming || 0 == self.listeningClients.count) {
      return;
    }
    NSUInteger clientCount = self.listeningClients.count;
    for (GCDAsyncSocket *client in self.listeningClients) {
      // Slow clients should fail/close instead of buffering indefinitely.
      [client writeData:chunk withTimeout:FRAME_TIMEOUT tag:0];
    }
    self.sentFramesCount++;
    self.sentBytesCount += chunk.length * clientCount;
    NSUInteger framerate = FBNormalizedMjpegFramerate(FBConfiguration.mjpegServerFramerate);
    if (0 == self.sentFramesCount % framerate) {
      [FBLogger verboseLog:[NSString stringWithFormat:@"MJPEG stats: clients=%@ sentFrames=%@ sentBytes=%@",
                            @(clientCount),
                            @(self.sentFramesCount),
                            @(self.sentBytesCount)]];
    }
  }
}

- (void)didClientConnect:(GCDAsyncSocket *)newClient
{
  [FBLogger logFmt:@"Got screenshots broadcast client connection at %@:%d", newClient.connectedHost, newClient.connectedPort];
  // Start broadcast only after there is any data from the client
  [newClient readDataWithTimeout:-1 tag:0];
}

- (void)didClientSendData:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    if ([self.listeningClients containsObject:client]) {
      return;
    }
  }

  [FBLogger logFmt:@"Starting screenshots broadcast for the client at %@:%d", client.connectedHost, client.connectedPort];
  NSString *streamHeader = [NSString stringWithFormat:@"HTTP/1.0 200 OK\r\nServer: %@\r\nConnection: close\r\nMax-Age: 0\r\nExpires: 0\r\nCache-Control: no-cache, private\r\nPragma: no-cache\r\nContent-Type: multipart/x-mixed-replace; boundary=--BoundaryString\r\n\r\n", SERVER_NAME];
  [client writeData:(id)[streamHeader dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:0];
  @synchronized (self.listeningClients) {
    [self.listeningClients addObject:client];
  }
}

- (void)didClientDisconnect:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    [self.listeningClients removeObject:client];
  }
  [FBLogger log:@"Disconnected a client from screenshots broadcast"];
}

- (void)stopStreaming
{
  self.isStreaming = NO;
  @synchronized (self.listeningClients) {
    NSArray<GCDAsyncSocket *> *clients = self.listeningClients.copy;
    [self.listeningClients removeAllObjects];
    for (GCDAsyncSocket *client in clients) {
      [client disconnect];
    }
  }
}

- (void)dealloc
{
  [self stopStreaming];
  [FBLogger verboseLog:@"FBMjpegServer deallocated"];
}

@end


#pragma mark - Diffuseur H.264

// --- Pourquoi ce serveur existe, et ce qu'il coute -------------------------
//
// Il sert le MEME ecran que FBMjpegServer, mais encode en H.264 par le materiel
// du telephone (VideoToolbox). Mesure du 2026-08-08 sur un iPhone XS Max :
// ~2 Mbit/s contre ~10, en definition NATIVE au lieu de 30 %.
//
// LA CHAINE EST ABSURDE, ET CE N'EST PAS DE NOUS. `FBScreenshot` ne rend que
// des donnees DEJA encodees : l'API de XCTest n'expose pas les pixels bruts. On
// est donc oblige de faire JPEG -> decodage -> pixels -> H.264. C'est aussi ce
// que fait DeviceKit, et ca lui coute 13 images/s sur les ~57 que la porte
// autorise.
//
// TROIS CHOSES QU'ON FAIT MIEUX QUE DEVICEKIT, chacune vue dans leur source :
//   . ils redimensionnent avec CoreImage MEME quand on demande 100 %. On ne
//     redimensionne pas du tout : la definition native est deja la bonne, et
//     reduire COUTE des images (53 img/s en 100 %, 35,7 en 50 %).
//   . ils capturent a une qualite JPEG de 0,9 codee en dur. Une image plus
//     legere se decode plus vite chez nous, et la mesure montre que la qualite
//     ne change RIEN au cout de la capture (52,8 a 53,1 img/s de 1 % a 25 %).
//   . ils ne peuvent pas forcer une image cle. Nous si -- d'ou une image nette
//     immediate a la connexion, au lieu d'attendre la suivante.

static const NSTimeInterval FBH264FrameTimeout = 1.0;
static const NSUInteger FBH264MaxFps = 60;
static const int32_t FBH264Bitrate = 4000000;          // 4 Mbit/s, comme DeviceKit
static const CGFloat FBH264CaptureQuality = 0.6;       // cf. commentaire ci-dessus
static const NSTimeInterval FBH264KeyFrameInterval = 2.0;

static NSString *const FBH264ServerName = @"WDA H264 Server";
static const char *FBH264QueueName = "H264 Screenshots Provider Queue";
static const uint8_t FBH264StartCode[4] = {0x00, 0x00, 0x00, 0x01};


@interface FBH264Server ()
@property (nonatomic, readonly) dispatch_queue_t backgroundQueue;
@property (nonatomic, readonly) NSMutableArray<GCDAsyncSocket *> *listeningClients;
@property (nonatomic, readonly) long long mainScreenID;
@property (atomic, assign) BOOL isStreaming;
@property (atomic, assign) BOOL needsKeyFrame;
@property (nonatomic, assign) VTCompressionSessionRef session;
@property (nonatomic, assign) size_t sessionWidth;
@property (nonatomic, assign) size_t sessionHeight;
@property (nonatomic, assign) int64_t frameIndex;

- (void)broadcastPayload:(NSData *)payload;

@end


/** Ecrit une unite NAL precedee de son code de depart. */
static void FBH264AppendNal(NSMutableData *out, const uint8_t *bytes, size_t length)
{
  [out appendBytes:FBH264StartCode length:sizeof(FBH264StartCode)];
  [out appendBytes:bytes length:length];
}

/**
 Rappel de VideoToolbox : une image encodee est prete.

 CONVERSION AVCC -> ANNEX-B, ET ELLE EST OBLIGATOIRE. VideoToolbox rend les
 unites NAL prefixees de leur LONGUEUR sur 4 octets. Un decodeur qui attend un
 flux (le navigateur, ffplay) veut des CODES DE DEPART 00 00 00 01. Recopier
 les octets tels quels donne un fichier que rien ne lit -- erreur payee le
 2026-08-07 en produisant des .h264 illisibles.
 Et sur une image cle on REEMET les parametres (SPS/PPS) : sans eux, un client
 qui arrive en cours de route n'a rien pour demarrer son decodeur.
 */
static void FBH264OutputCallback(void *outputCallbackRefCon,
                                 void *sourceFrameRefCon,
                                 OSStatus status,
                                 VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer)
{
  if (noErr != status || NULL == sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }
  FBH264Server *server = (__bridge FBH264Server *)outputCallbackRefCon;
  if (nil == server || !server.isStreaming) {
    return;
  }

  BOOL isKeyFrame = YES;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (NULL != attachments && CFArrayGetCount(attachments) > 0) {
    CFDictionaryRef attachment = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    isKeyFrame = !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
  }

  NSMutableData *payload = [NSMutableData data];

  if (isKeyFrame) {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    size_t parameterSetCount = 0;
    if (NULL != format
        && noErr == CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, NULL, NULL,
                                                                       &parameterSetCount, NULL)) {
      for (size_t i = 0; i < parameterSetCount; i++) {
        const uint8_t *parameterSet = NULL;
        size_t parameterSetLength = 0;
        if (noErr == CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &parameterSet,
                                                                        &parameterSetLength,
                                                                        NULL, NULL)) {
          FBH264AppendNal(payload, parameterSet, parameterSetLength);
        }
      }
    }
  }

  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
  size_t totalLength = 0;
  char *rawBuffer = NULL;
  if (NULL == block
      || noErr != CMBlockBufferGetDataPointer(block, 0, NULL, &totalLength, &rawBuffer)) {
    return;
  }

  const size_t prefixLength = 4;
  size_t offset = 0;
  while (offset + prefixLength <= totalLength) {
    uint32_t nalLength = 0;
    memcpy(&nalLength, rawBuffer + offset, prefixLength);
    nalLength = CFSwapInt32BigToHost(nalLength);
    if (0 == nalLength || offset + prefixLength + (size_t)nalLength > totalLength) {
      break;
    }
    FBH264AppendNal(payload, (const uint8_t *)(rawBuffer + offset + prefixLength), nalLength);
    offset += prefixLength + (size_t)nalLength;
  }

  if (payload.length > 0) {
    [server broadcastPayload:payload];
  }
}


@implementation FBH264Server

- (instancetype)init
{
  if ((self = [super init])) {
    _isStreaming = YES;
    _needsKeyFrame = YES;
    _session = NULL;
    _sessionWidth = 0;
    _sessionHeight = 0;
    _frameIndex = 0;
    _listeningClients = [NSMutableArray array];
    _mainScreenID = [XCUIScreen.mainScreen displayID];
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                              QOS_CLASS_UTILITY, 0);
    _backgroundQueue = dispatch_queue_create(FBH264QueueName, attributes);
    __weak typeof(self) weakSelf = self;
    dispatch_async(_backgroundQueue, ^{
      [weakSelf streamFrame];
    });
  }
  return self;
}

- (NSUInteger)normalizedFramerate
{
  // Reglage DEDIE. Lire celui du MJPEG donnait 10 img/s par defaut, donc
  // 8,8 mesurees au premier essai reel du 2026-08-08.
  NSUInteger framerate = (NSUInteger)FBConfiguration.h264Framerate;
  return (0 == framerate || framerate > FBH264MaxFps) ? FBH264MaxFps : framerate;
}

- (void)scheduleNextFrameWithInterval:(uint64_t)interval timeStarted:(uint64_t)timeStarted
{
  if (!self.isStreaming) {
    return;
  }
  uint64_t elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - timeStarted;
  int64_t remaining = (int64_t)interval - (int64_t)elapsed;
  __weak typeof(self) weakSelf = self;
  if (remaining > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, remaining), self.backgroundQueue, ^{
      [weakSelf streamFrame];
    });
  } else {
    dispatch_async(self.backgroundQueue, ^{
      [weakSelf streamFrame];
    });
  }
}

- (void)streamFrame
{
  if (!self.isStreaming) {
    return;
  }
  uint64_t interval = (uint64_t)(1.0 / (double)[self normalizedFramerate] * NSEC_PER_SEC);
  uint64_t timeStarted = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

  BOOL hasClients = NO;
  @synchronized (self.listeningClients) {
    hasClients = self.listeningClients.count > 0;
  }
  if (!hasClients) {
    // Personne ne regarde : on ne capture RIEN, et on relache l'encodeur. Le
    // telephone ne chauffe pas pour une image que personne ne verra.
    [self invalidateSession];
    [self scheduleNextFrameWithInterval:interval timeStarted:timeStarted];
    return;
  }

  NSError *error;
  NSData *jpegData = [FBScreenshot takeInOriginalResolutionWithScreenID:self.mainScreenID
                                                    compressionQuality:FBH264CaptureQuality
                                                                   uti:UTTypeJPEG
                                                               timeout:FBH264FrameTimeout
                                                                 error:&error];
  if (nil == jpegData) {
    [FBLogger logFmt:@"H264: capture impossible: %@", error.description];
    [self scheduleNextFrameWithInterval:interval timeStarted:timeStarted];
    return;
  }

  UIImage *image = [UIImage imageWithData:jpegData];
  CGImageRef cgImage = image.CGImage;
  if (NULL == cgImage) {
    [self scheduleNextFrameWithInterval:interval timeStarted:timeStarted];
    return;
  }

  [self encodeImage:cgImage];
  [self scheduleNextFrameWithInterval:interval timeStarted:timeStarted];
}

- (BOOL)prepareSessionForWidth:(size_t)width height:(size_t)height
{
  if (NULL != self.session && width == self.sessionWidth && height == self.sessionHeight) {
    return YES;
  }
  [self invalidateSession];

  VTCompressionSessionRef session = NULL;
  OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault,
                                               (int32_t)width, (int32_t)height,
                                               kCMVideoCodecType_H264,
                                               NULL, NULL, NULL,
                                               FBH264OutputCallback,
                                               (__bridge void *)self,
                                               &session);
  if (noErr != status || NULL == session) {
    [FBLogger logFmt:@"H264: creation de la session impossible (%d)", (int)status];
    return NO;
  }

  // Baseline + AllowFrameReordering=false : AUCUNE image B, donc aucun
  // reordonnancement. Un decodeur qui croit devoir reordonner met les images en
  // reserve et n'en rend qu'aux images cles -- symptome vu le 08/08 sur le
  // decodeur materiel de Chrome : 166 images fournies, 6 rendues.
  VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel,
                       kVTProfileLevel_H264_Baseline_AutoLevel);

  int32_t bitrate = FBH264Bitrate;
  CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bitrate);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
  CFRelease(bitrateRef);

  int32_t expectedFps = (int32_t)[self normalizedFramerate];
  CFNumberRef fpsRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &expectedFps);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
  CFRelease(fpsRef);

  double keyFrameInterval = FBH264KeyFrameInterval;
  CFNumberRef keyFrameRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType,
                                           &keyFrameInterval);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyFrameRef);
  CFRelease(keyFrameRef);

  VTCompressionSessionPrepareToEncodeFrames(session);

  self.session = session;
  self.sessionWidth = width;
  self.sessionHeight = height;
  self.needsKeyFrame = YES;
  [FBLogger logFmt:@"H264: session %zux%zu @ %d img/s, %d bit/s",
   width, height, (int)expectedFps, (int)bitrate];
  return YES;
}

- (void)invalidateSession
{
  if (NULL != self.session) {
    VTCompressionSessionCompleteFrames(self.session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(self.session);
    CFRelease(self.session);
    self.session = NULL;
    self.sessionWidth = 0;
    self.sessionHeight = 0;
  }
}

- (CVPixelBufferRef)pixelBufferFromImage:(CGImageRef)image CF_RETURNS_RETAINED
{
  size_t width = CGImageGetWidth(image);
  size_t height = CGImageGetHeight(image);
  NSDictionary *attributes = @{
    (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
  };
  CVPixelBufferRef pixelBuffer = NULL;
  if (kCVReturnSuccess != CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                              kCVPixelFormatType_32BGRA,
                                              (__bridge CFDictionaryRef)attributes,
                                              &pixelBuffer)) {
    return NULL;
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer),
                                               width, height, 8,
                                               CVPixelBufferGetBytesPerRow(pixelBuffer),
                                               colorSpace,
                                               kCGImageAlphaNoneSkipFirst
                                               | kCGBitmapByteOrder32Little);
  if (NULL != context) {
    // Aucun redimensionnement : la definition native est deja celle qu'on veut.
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
  }
  CGColorSpaceRelease(colorSpace);
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
  return pixelBuffer;
}

- (void)encodeImage:(CGImageRef)image
{
  if (![self prepareSessionForWidth:CGImageGetWidth(image) height:CGImageGetHeight(image)]) {
    return;
  }
  CVPixelBufferRef pixelBuffer = [self pixelBufferFromImage:image];
  if (NULL == pixelBuffer) {
    return;
  }

  CMTime presentationTime = CMTimeMake(self.frameIndex++, (int32_t)[self normalizedFramerate]);
  NSDictionary *frameProperties = nil;
  if (self.needsKeyFrame) {
    // L'IMAGE CLE A LA DEMANDE, et c'est ce que DeviceKit ne sait pas faire. Un
    // client qui arrive voit une image nette TOUT DE SUITE au lieu d'attendre la
    // cle suivante, et un decodeur qui a decroche se recale immediatement --
    // c'est le remede aux artefacts constates le 08/08.
    frameProperties = @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES};
    self.needsKeyFrame = NO;
  }

  VTCompressionSessionEncodeFrame(self.session, pixelBuffer, presentationTime, kCMTimeInvalid,
                                  (__bridge CFDictionaryRef)frameProperties, NULL, NULL);
  CVPixelBufferRelease(pixelBuffer);
}

- (void)broadcastPayload:(NSData *)payload
{
  @synchronized (self.listeningClients) {
    if (!self.isStreaming || 0 == self.listeningClients.count) {
      return;
    }
    for (GCDAsyncSocket *client in self.listeningClients) {
      // Un client lent doit tomber, pas accumuler : le retard qu'on garderait
      // en memoire ne se resorbe jamais.
      [client writeData:payload withTimeout:FBH264FrameTimeout tag:0];
    }
  }
}

#pragma mark - FBTCPSocketDelegate

- (void)didClientConnect:(GCDAsyncSocket *)newClient
{
  [FBLogger logFmt:@"H264: client connecte depuis %@:%d",
   newClient.connectedHost, newClient.connectedPort];
  [newClient readDataWithTimeout:-1 tag:0];
}

- (void)didClientSendData:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    if ([self.listeningClients containsObject:client]) {
      return;
    }
  }
  NSString *header = [NSString stringWithFormat:
                      @"HTTP/1.0 200 OK\r\nServer: %@\r\nConnection: close\r\n"
                      @"Cache-Control: no-cache, no-store, must-revalidate\r\n"
                      @"Content-Type: video/h264\r\n\r\n", FBH264ServerName];
  [client writeData:(id)[header dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:0];
  @synchronized (self.listeningClients) {
    [self.listeningClients addObject:client];
  }
  // Le nouveau venu n'a aucune reference : il lui faut une image cle, sinon son
  // decodeur ne rend rien du tout et l'ecran reste noir.
  self.needsKeyFrame = YES;
}

- (void)didClientDisconnect:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    [self.listeningClients removeObject:client];
  }
  [FBLogger log:@"H264: client deconnecte"];
}

- (void)stopStreaming
{
  self.isStreaming = NO;
  @synchronized (self.listeningClients) {
    NSArray<GCDAsyncSocket *> *clients = self.listeningClients.copy;
    [self.listeningClients removeAllObjects];
    for (GCDAsyncSocket *client in clients) {
      [client disconnect];
    }
  }
  [self invalidateSession];
}

- (void)dealloc
{
  [self stopStreaming];
  [FBLogger verboseLog:@"FBH264Server deallocated"];
}

@end
