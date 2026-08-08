# Pourquoi ce fork

Fork de `appium/WebDriverAgent`, utilise par le projet iFARM (ferme d'iPhones
pilotee depuis Windows, sans Mac).

Objectif : produire un `.ipa` de WebDriverAgentRunner **pour un vrai appareil**
en se servant des runners macOS de GitHub Actions, puisqu'on n'a pas de Mac.
Le workflow `wda-package.yml` d'appium fait deja exactement ca : il compile pour
`generic/platform=iOS` et publie `WebDriverAgentRunner-Runner.zip`.

Etape suivante prevue : y greffer un serveur video H.264 (VideoToolbox) pour
que le meme runner serve l'image ET le controle, au lieu d'un second runner
XCUITest a cote. Mesure du 2026-08-08 : deux runners qui se partagent la
capture font tomber la cadence de 23,8 a 12,8 images/s.

Rien n'est modifie pour l'instant : le premier build sert a prouver la chaine.
