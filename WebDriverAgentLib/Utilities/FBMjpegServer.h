/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBTCPSocket.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBMjpegServer : NSObject <FBTCPSocketDelegate>

/**
 The default constructor for the screenshot bradcaster service.
 This service sends low resolution screenshots 10 times per seconds
 to all connected clients.
 */
- (instancetype)init;

/**
 Stops screenshot broadcasting and prevents future scheduling.
 */
- (void)stopStreaming;

@end


/**
 Diffuseur H.264 : le MEME ecran, encode en materiel par VideoToolbox au lieu
 d'une suite d'images JPEG independantes.

 POURQUOI. Mesure du 2026-08-08 sur un iPhone XS Max (iOS 16.4.1) : le MJPEG de
 WDA rend 15,5 images/s pour ~10 Mbit/s a 30 % de definition, la ou le meme
 telephone sert du H.264 a ~40 images/s pour ~2 Mbit/s en definition NATIVE.
 A vingt telephones, 40 Mbit/s au lieu de 200.

 POURQUOI ICI, ET PAS DANS SES PROPRES FICHIERS. Le projet est en
 `objectVersion 54`, sans groupes synchronises : ajouter un fichier imposerait
 de modifier `project.pbxproj` a la main, sans Xcode pour le verifier. Les deux
 classes font le meme metier -- diffuser l'ecran -- donc elles cohabitent. A
 separer le jour ou quelqu'un ouvrira le projet dans un vrai Xcode.

 CE QU'ELLE NE PEUT PAS FAIRE, et ce n'est pas un defaut d'implementation : la
 capture passe par `FBScreenshot`, qui ne rend que des donnees DEJA encodees --
 l'API de XCTest n'expose pas les pixels bruts. La chaine est donc forcement
 JPEG -> decodage -> pixels -> H.264. Mesure : cette porte plafonne a ~57
 images/s sur ce telephone, quelle que soit la qualite demandee. 60 est la
 valeur maximale qu'on a le droit de DEMANDER, pas une cadence promise.
 */
@interface FBH264Server : NSObject <FBTCPSocketDelegate>

- (instancetype)init;

/**
 Arrete la diffusion et empeche toute reprogrammation.
 */
- (void)stopStreaming;

@end

NS_ASSUME_NONNULL_END
