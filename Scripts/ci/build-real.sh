#!/bin/bash

# iFARM 2026-08-08 : COMPILATION EN RELEASE, et ce n'est pas un detail.
#
# Sans `-configuration`, `build-for-testing` prend le reglage de l'action Test du
# schema -- c'est-a-dire DEBUG : aucune optimisation du compilateur, assertions
# actives, comptage de references non optimise. DeviceKit, lui, se compile en
# Release (leur Makefile : `CONFIGURATION ?= Release`).
#
# On comparait donc du code NON OPTIMISE a du code OPTIMISE, sur une boucle qui
# traite 3,3 millions de pixels par image et ou WDA construit sa requete de
# capture par reflexion (NSInvocation) a chaque appel. L'ecart Debug/Release y
# est couramment d'un facteur 2 -- l'ordre de grandeur qui nous manquait.
#
# Ca ne se voit ni dans le code source, ni dans le binaire : seulement en lisant
# comment chacun est CONSTRUIT.
xcodebuild clean build-for-testing \
  -configuration Release \
  -project WebDriverAgent.xcodeproj \
  -derivedDataPath $DERIVED_DATA_PATH \
  -scheme $SCHEME \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64

pushd $WD

# iFARM 2026-08-08 : ON GARDE LES FRAMEWORKS DE TEST, contrairement a appium.
#
# Le commentaire d'appium, conserve pour memoire :
#   - to remove test packages to refer to the device local instead of embedded
#     ones : XCTAutomationSupport, XCTest, XCTestCore, XCUIAutomation, XCUnit.
#   - Xcode 16 started generating 5.9MB of 'Testing.framework'.
#   - libXCTestSwiftSupport is used for Swift testing.
#
# POURQUOI ON NE LES RETIRE PLUS. Les faire retirer revient a utiliser le XCTest
# LOCAL de l'appareil -- celui d'iOS 16.4.1 sur l'iPhone XS Max, une
# implementation de 2023. DeviceKit embarque celui du SDK 18.4, et sa capture est
# stable la ou la notre etait erratique (26 a 312 ms). Meme API, implementation
# differente, et ca ne se voit PAS dans le code source : seulement en ouvrant les
# deux .ipa cote a cote (6,2 Mo contre 811 Ko).
#
# Le doute << un XCTest recent plante sur iOS 16 >> est demenit par les faits, et
# deux fois : DeviceKit les embarque et tourne sur ce telephone, et notre propre
# build les embarquant a demarre sur iOS 16.4.1 (verifie le 2026-08-08).
#
# Cout : l'ipa passe de ~0,8 a ~6 Mo. Sans consequence, il s'installe une fois.
# Pour revenir au comportement d'appium, remettre les trois exclusions :
#   -x "$SCHEME-Runner.app/Frameworks/XC*.framework*" \
#      "$SCHEME-Runner.app/Frameworks/Testing.framework*" \
#      "$SCHEME-Runner.app/Frameworks/libXCTestSwiftSupport.dylib"
zip -r $ZIP_PKG_NAME $SCHEME-Runner.app
popd
mv $WD/$ZIP_PKG_NAME ./
