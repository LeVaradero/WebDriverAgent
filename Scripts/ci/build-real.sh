#!/bin/bash

# iFARM 2026-08-08 : ON REVIENT AUX REGLAGES D'APPIUM, ET C'EST MESURE.
#
# J'ai essaye deux changements au niveau de la CONSTRUCTION, en croyant copier
# DeviceKit. Les deux sont des REGRESSIONS, mesurees notre serveur seul sur le
# telephone, ecran qui bouge, aucun geste :
#
#   reglages d'appium (Debug, XCTest du systeme) : capture 26-48 ms, conversion
#     7 ms, encodage 0,3 ms  ->  jusqu'a 40 img/s
#   Release + XCTest embarque : capture 72-84 ms, conversion 22 ms, encodage
#     3,4 ms  ->  9 img/s
#
# TOUT ralentit, y compris notre propre conversion et notre encodage. Le plus
# probable est l'XCTest embarque : charger un moteur de 5,9 Mo depuis le paquet
# au lieu de celui du systeme n'a aucune raison d'etre plus rapide sur iOS 16.
#
# ⚠️ FAUTE DE METHODE A NE PAS REFAIRE : j'ai empile les deux changements sans
# mesurer entre les deux, donc je ne peux pas dire lequel coute quoi. Un
# changement a la fois, une mesure a chaque fois.
#
# Et les deux mesures qui les ont motives etaient FAUSSES : elles comparaient
# notre serveur seul a DeviceKit... alors que DeviceKit tournait aussi pendant la
# mesure de notre serveur. C'est le proprietaire qui l'a releve.
xcodebuild clean build-for-testing   -project WebDriverAgent.xcodeproj   -derivedDataPath $DERIVED_DATA_PATH   -scheme $SCHEME   -destination "$DESTINATION"   CODE_SIGNING_ALLOWED=NO ARCHS=arm64

pushd $WD

# Commentaire d'origine d'appium, et on suit leur choix :
# - to remove test packages to refer to the device local instead of embedded ones
#   XCTAutomationSupport.framework, XCTest.framework, XCTestCore.framework,
#   XCUIAutomation.framework, XCUnit.framework.
# - Xcode 16 started generating 5.9MB of 'Testing.framework'.
# - libXCTestSwiftSupport is used for Swift testing.
zip -r $ZIP_PKG_NAME $SCHEME-Runner.app     -x "$SCHEME-Runner.app/Frameworks/XC*.framework*"        "$SCHEME-Runner.app/Frameworks/Testing.framework*"        "$SCHEME-Runner.app/Frameworks/libXCTestSwiftSupport.dylib"
popd
mv $WD/$ZIP_PKG_NAME ./
