#!/bin/bash

xcodebuild clean build-for-testing \
  -project WebDriverAgent.xcodeproj \
  -derivedDataPath $DERIVED_DATA_PATH \
  -scheme $SCHEME \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64

pushd $WD

# The reason why here excludes several frameworks are:
# - to remove test packages to refer to the device local instead of embedded ones
#   XCTAutomationSupport.framework, XCTest.framewor, XCTestCore.framework,
#   XCUIAutomation.framework, XCUnit.framework.
#   This can be excluded only for real devices.
# - Xcode 16 started generating 5.9MB of 'Testing.framework', but it might not be necessary for WDA.
# - libXCTestSwiftSupport is used for Swift testing. WDA doesn't include Swift stuff, thus this is not needed.
# iFARM 2026-08-08 : ON GARDE LES FRAMEWORKS DE TEST, contrairement a appium.
#
# POURQUOI. Les exclusions retirees ici faisaient tourner le runner sur le XCTest
# LOCAL de l'appareil -- celui d'iOS 16.4.1 sur l'iPhone XS Max, donc une
# implementation de 2023. DeviceKit embarque celui du SDK 18.4, et sa capture est
# stable a ~19 ms la ou la notre etait erratique entre 26 et 312 ms. Meme API,
# implementation differente : c'est la seule difference qui restait entre leur
# paquet et le notre, et elle ne se voit PAS dans le code source -- seulement en
# ouvrant les deux .ipa (6,2 Mo contre 811 Ko).
#
# Le doute << un XCTest recent plante sur iOS 16 >> est demenit par les faits :
# DeviceKit les embarque et tourne sur ce meme telephone.
#
# Cout : l'ipa passe de ~0,8 a ~6 Mo. Pour revenir au comportement d'appium, il
# suffit de remettre les trois exclusions `-x`.
zip -r $ZIP_PKG_NAME $SCHEME-Runner.app
popd
mv $WD/$ZIP_PKG_NAME ./
