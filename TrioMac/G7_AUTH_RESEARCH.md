# Aktive G7-Authentifizierung auf macOS: Portierungsbefund

Stand: 24.10.2026. Reine Prüfung öffentlich lesbarer Quellen und lokaler Projektmetadaten. Keine Geräteverbindung, kein Sensorcode, keine privaten Nutzer-/Geräteschlüssel, keine Binäranalyse und kein Authentifizierungslauf. Diese Datei enthält weder fremden Quellcode noch Schlüssel- oder Zertifikatswerte.

## Entscheidung

Ein **isoliertes Swift-Testmodul für Protokollformat, Zustandsübergänge und synthetische Kryptotests ist jetzt sinnvoll**. Ein vollständig funktionsfähiger und für Trio unverändert MIT-lizenzierter aktiver G7-Treiber lässt sich aus dem untersuchten xDrip-Modul dagegen **noch nicht begründen**.

Vier offene Punkte verhindern diese weitergehende Aussage:

1. Die maßgeblichen xDrip-Klassen haben keine permissive Einzellizenz; die Repository-Lizenz ist GPLv3. Eine Übersetzung nach Swift beseitigt diese Lizenzanforderungen nicht.
2. Erstmaliges G7-Bonding verlangt zusätzlich zur vierstelligen PIN zwei Zertifikatsdatenblöcke und einen privaten Signaturschlüssel. Herkunft, zulässige Bereitstellung und Akzeptanz eigener Identitäten sind in den geprüften Quellen nicht geklärt.
3. Die EC-JPAKE-Operationen benötigen mehr als die öffentlichen CryptoKit-P256-Signatur-/ECDH-Schnittstellen. Ein geeigneter, überprüfter Mathematik-Backend ist noch auszuwählen.
4. Androids explizites Bonding und dessen Wiederherstellung sind nicht direkt auf CoreBluetooth übertragbar. Für macOS gibt es hier noch keinen nachgewiesenen Erstkopplungs-/Wiederverbindungslauf.

Das sind konkrete Arbeitsgrenzen, kein Nachweis technischer Unmöglichkeit. xDrip dokumentiert aktive G7-Kopplung auf Android. Die vorhandene Swift-Integration bleibt davon verschieden: G7SensorKit beobachtet eine bereits authentifizierte Sitzung und verlangt die Dexcom-App für Kopplung und Verwaltung. [xDrip-Anleitung](https://navid200.github.io/xDrip/docs/Dexcom/G7.html), [G7SensorKit](https://github.com/LoopKit/G7SensorKit/blob/main/G7SensorKit/G7CGMManager/G7Sensor.swift#L299), [Setup-Hinweis](https://github.com/LoopKit/G7SensorKit/blob/main/G7SensorKitUI/Views/G7StartupView.swift#L29)

## Reproduzierbarer Quellenstand

Untersucht wurde xDrip-Commit **`c42cf55c6b972215654bc2a34ce563c87a7aa594`**, Commitdatum 23.10.2026. Die vollständige GitHub-Baumantwort war nicht abgeschnitten. Relevant sind `libkeks`, `ipluginda` sowie die beiden Android-Klassen `Ob1G5StateMachine` und `Ob1G5CollectionService`. Verweise auf xDrip in diesem Dokument sind auf diesen Commit fixiert. [Commit](https://github.com/NightscoutFoundation/xDrip/commit/c42cf55c6b972215654bc2a34ce563c87a7aa594)

Der aktuelle Android-Pfad ruft `Loader.getLocalInstance` auf; für `keks` liefert dieser die eingebundene Java-Klasse. Ein älterer dynamischer Plugin-Loader existiert daneben, wird hier aber nicht benötigt. Das Auth-Modul ist daher nicht schon wegen einer zwingenden Android-`.so` oder eines herunterzuladenden proprietären Plugins unportierbar. Die eingecheckte Interface-JAR wurde nicht gelesen; Gradle bindet das vorhandene Quellprojekt `ipluginda` ein. [Loader](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/app/src/main/java/com/eveningoutpost/dexdrip/plugin/Loader.java#L48), [Builddatei](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/build.gradle)

## Lizenz und eingebundene Klassen

| Bestandteil | Beobachtung | Konsequenz für Trio |
| --- | --- | --- |
| `Plugin`, `Context`, `Calc`, `Curve`, `Packet`, `JECPoint`, `KeyPair`, `DSAChallenger`, Nachrichten-/Hilfsklassen und `IPluginDA` | Keine abweichende permissive Lizenz im jeweiligen geprüften Dateikopf; Repository enthält GPLv3. | Eine direkte Übernahme/Übersetzung nicht als MIT-eigenen Code deklarieren. GPL-konforme Gesamtverteilung oder gesonderte Erlaubnis vor Integration klären. |
| `jamorham.libkeks.SHA256` | Ausdrücklicher MIT-Hinweis, Fabian Meyer, 2017. | Bei Übernahme Hinweis erhalten; einfacher ist für Standard-SHA256 CryptoKit. Das macht die übrigen Klassen nicht MIT-lizenziert. |
| BouncyCastle `bcpkix`/`bcprov` 1.68 | Java-Kryptoabhängigkeiten; permissive MIT-artige Lizenz mit Hinweispflicht. | Bei Portierung durch einen geeigneten Apple-/C-Backend ersetzen; die Java-API nicht voraussetzen. |
| Lombok | Buildzeit-Codegenerierung; MIT, mit zusätzlichen Hinweisen für eigene eingebundene Komponenten. | Für einen Swift-Port entbehrlich. |
| AndroidX/Android-Annotationen, Java-/Android-Buildhilfen | Plattform-/Buildabhängigkeiten, keine Protokollprimitiven. | Im reinen Swift-Modul weglassen. Keine Freigabe einer unverändert weiterverteilten Android-Abhängigkeitskette aus diesem Review ableiten. |

Quellen: [xDrip-Lizenz](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/LICENSE), [SHA256-Dateikopf](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/libkeks/SHA256.java), [BouncyCastle 1.68](https://github.com/bcgit/bc-java/blob/r1rv68/LICENSE.html), [Lombok](https://github.com/projectlombok/lombok/blob/master/LICENSE).

Trios [Root-Lizenz](../LICENSE.txt) ist MIT. MIT und GPL sind nicht pauschal unvereinbar; entscheidend ist, dass eine aus GPL-Code abgeleitete integrierte Fassung nicht einfach unter MIT allein verteilt werden kann. GPLv3 §§5–6 enthalten Anforderungen an modifizierte Werke und korrespondierenden Quellcode. Die Verteilungsentscheidung für die gesamte App ist offen, ebenso der konkrete Apple-Verteilungsweg. Diese Quellenprüfung ersetzt keine abschließende rechtliche Freigabe. Ein unabhängiger Entwurf aus öffentlichen Protokollstandards ist eine andere Möglichkeit; ein nachträgliches Umbenennen der gelesenen Java-Klassen wäre keine belastbare Trennung.

## Kryptografischer Umfang

| Teil | Beobachtetes Verhalten | Portierungsbedarf |
| --- | --- | --- |
| EC-JPAKE | `secp256r1`/NIST P-256, zufällige Skalare, Punktaddition/-subtraktion/-multiplikation und Schnorr-Wissensnachweise. | Beliebige gültige Kurvenpunkte und skalare Arithmetik, nicht nur ECDH. Punkt-/Skalarvalidierung und sichere Zufallsquelle. |
| Paketformat | Zwei affine Punkte plus Beweis-Skalar, jeweils 32-Byte-Felder; insgesamt 160 Byte. | Exakte Breite, Reihenfolge und Endianness; überlange/verkürzte/ungültige Eingaben begrenzen. |
| Schlüsselableitung | SHA256 über die x-Koordinate des gemeinsamen Punktes, anschließend Verkürzung auf 16 Byte. | Deterministische Vergleichsvektoren und Tests für führende Nullbytes. |
| Auth-Challenge | AES-ECB ohne Padding über einen 16-Byte-Block; Ergebnis wird verkürzt. | Kein Austausch gegen AES-GCM: das wäre ein anderes Protokoll. Standard-AES-Implementierung verwenden. |
| Signatur | ECDSA mit SHA256; privater Schlüssel aus PKCS#8, Signatur als feste `r`-/`s`-Felder. | Importformat und DER-gegen-Raw-Konvertierung prüfen; synthetische Schlüssel reichen für Tests. |

Quellen: [Curve](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/keks/Curve.java), [Packet](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/keks/Packet.java), [Calc](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/keks/Calc.java), [AESwrapper](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/keks/util/AESwrapper.java), [DSAChallenger](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/keks/DSAChallenger.java).

Zwei leicht zu übersehende Formatdetails: `Digest.update` stellt neue Blöcke vor die bisherigen; eine gewöhnliche inkrementelle SHA256-Übersetzung wäre deshalb nicht automatisch äquivalent. `Util.hexStringToByteArray` vertauscht die Nibbles seiner statischen Hexdarstellungen. Das ist keine Aufforderung, Schlüsselmaterial zu dekodieren: Der Port braucht spezifizierte Byteformate und synthetische Vergleichsfälle. [Digest](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/libkeks/Digest.java), [Util](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/keks/util/Util.java)

Apples öffentliche `P256`-API dokumentiert KeyAgreement und Signing, keine allgemeine Punktarithmetik für J-PAKE. Der Algorithmus ist in RFC 8236 beschrieben; dieses Dokument spezifiziert jedoch nicht Dexcoms vollständiges BLE-/Zertifikatsprotokoll. Trio löst bereits CryptoSwift 1.8.2, BigInt 1.24.0 und BlueECC 1.2.201 auf. Ihre bloße Anwesenheit belegt keine passende J-PAKE-Implementierung. Vor neuen Abhängigkeiten diese vorhandenen APIs gezielt prüfen. [Apple P256](https://developer.apple.com/documentation/cryptokit/p256), [RFC 8236](https://www.rfc-editor.org/rfc/rfc8236), [Package.resolved](../Trio.xcworkspace/xcshareddata/swiftpm/Package.resolved)

## Zertifikate, Schlüssel und Persistenz

Der Erstkopplungspfad für den vierstelligen G7-Code verlangt nach erfolgreicher J-PAKE-Authentifizierung, solange noch kein Bond besteht, drei zusätzliche Teile. `Context.validateParts` prüft deren Vorhandensein; ohne sie endet der Pfad mit einem Fehler. Teil A/B werden als Zertifikatsdaten versendet, Teil C wird als privater Schlüssel für die Challenge-Signatur verwendet. `Ob1G5CollectionService` führt diese Teile aus separaten Einstellungen dem Plugin zu. Der vierstellige Code allein genügt diesem Pfad somit nicht. [Context](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/keks/Context.java), [Erstkopplungszweig](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/keks/Plugin.java#L251), [Übergabe durch Android](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/app/src/main/java/com/eveningoutpost/dexdrip/services/Ob1G5CollectionService.java#L1655)

**Ressourcenblocker:** Die geprüften Dateien erklären nicht, wer diese Identität ausstellt, welche Rechte deren Weiterverteilung erlaubt oder ob selbst erzeugte Zertifikate akzeptiert werden. Eine öffentliche Konfigurationsanleitung beweist keine Lizenz für darin transportierte Zugangsdaten. Keine QR-Konfiguration oder Schlüsselwerte wurden extrahiert, dekodiert oder in diese Datei übernommen. Vor einem echten Erstkopplungstreiber ist ein nachvollziehbarer Bereitstellungsweg nötig.

Ein abgeleiteter 16-Byte-Sitzungsschlüssel wird gesondert gespeichert und bei Wiederverbindung erneut benutzt. Android ordnet ihn der Geräteadresse zu. Auf dem Mac braucht es eine eigene Zuordnung zu CoreBluetooth-Identität plus validierter Sensoridentität, mit Keychain-Speicherung und Fehlerbehandlung für veraltete Identitäten. Keine Annahme, dass ein iPhone-Bond oder Android-Schlüssel auf dem Mac wiederverwendbar ist. [Persistenz](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/app/src/main/java/com/eveningoutpost/dexdrip/services/Ob1G5CollectionService.java#L1060)

## BLE- und Bonding-Grenze

`IPluginDA` trennt Byteverarbeitung vom Transport: Verbindungsereignis, eingehende Auth-/Datenfragmente, nächste ausgehende Pakete, Bond-Anforderung und Persistenz. Diese Trennung ist für ein Offline-Testmodul brauchbar. Der Android-Adapter sendet zusätzliche Auth-Daten ohne Antwort in 20-Byte-Stücken und danach das Auth-Kommando mit Antwort. Seine Wartezeiten sind Implementierungsdetails, kein Beweis einer macOS-tauglichen Ablaufsteuerung. [Interface](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/ipluginda/src/main/java/com/eveningoutpost/dexdrip/plugin/IPluginDA.java), [Transport](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/app/src/main/java/com/eveningoutpost/dexdrip/g5model/Ob1G5StateMachine.java#L202)

Android nutzt `BluetoothDevice.createBond`, Bondstatus-Ereignisse und teilweise reflektiertes `removeBond`. Die geprüften öffentlichen Apple-Schnittstellen `CBPeripheral`/`CBCentralManager` enthalten keine entsprechenden expliziten Create-/Remove-Bond-Methoden. Ein Mac-Adapter muss ausschließlich den öffentlichen System-Kopplungsablauf verwenden; das Löschen alter Bonds darf nicht durch private APIs ersetzt werden. Notifications, Write-Bestätigungen und `canSendWriteWithoutResponse` sind auf CoreBluetooth übertragbare Bausteine. Erstkopplung, Benutzerabbruch, Wiederverbindung und ungültiger Bond bleiben praktisch zu validieren. [Android-Implementierung](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/app/src/main/java/com/eveningoutpost/dexdrip/services/Ob1G5CollectionService.java#L1871), [Android-API](https://developer.android.com/reference/android/bluetooth/BluetoothDevice#createBond()), [Apple CBPeripheral](https://developer.apple.com/documentation/corebluetooth/cbperipheral), [Apple CBCentralManager](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager)

## Vorhandene Tests und kleinstes sinnvolles Modul

Im geprüften Commit enthalten `libkeks` und `ipluginda` **keine eingecheckten Unit-Testdateien oder Golden-Vektoren**. Gradle deklariert JUnit/Mockito/PowerMock, das allein ist kein Testnachweis. `Umbilical.unitTest()` ruft Schnittstellenmethoden ohne Assertions auf und ersetzt keine Protokolltests. [Modulbaum](https://github.com/NightscoutFoundation/xDrip/tree/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks), [Umbilical](https://github.com/NightscoutFoundation/xDrip/blob/c42cf55c6b972215654bc2a34ce563c87a7aa594/libkeks/src/main/java/jamorham/keks/Umbilical.java)

Eine unabhängige Referenz für **generische** EC-JPAKE-Tests gibt es bei Mbed TLS: Parameter-, Rollen-, Korruptions- und Rundentestvektoren. Version 3.6.4 bietet Apache-2.0 oder GPL-2.0-or-later zur Wahl. Dies ist eine mögliche Testreferenz, keine Auswahl dieser Version für Produktbetrieb und kein G7-Interoperabilitätsbeweis; Framing, Identitäten und Transcript-Hash müssen separat übereinstimmen. [Testvektoren](https://github.com/Mbed-TLS/mbedtls/blob/mbedtls-3.6.4/tests/suites/test_suite_ecjpake.data), [Lizenz](https://github.com/Mbed-TLS/mbedtls/blob/mbedtls-3.6.4/LICENSE)

Empfohlener erster Implementierungsschritt: ein eigenständiges, nicht in Trio eingebundenes SwiftPM-Testziel `G7AuthProtocolLab` ohne CoreBluetooth, Netzwerk, Keychain oder Therapieimporte. Eigene Typen für Eingangsereignis, Sitzungsphase und ausgehende Aktion; kein Kopieren des Java-Zustandsautomaten. Zunächst nur folgende überprüfbare Ergebnisse:

1. Begrenzte Paket-/Fragmentparser: 160-Byte-Rundenformat, feste Feldbreiten, Abbruch bei Überlauf, falscher Phase, ungültiger Länge und Timeout.
2. Synthetische Zustandsfolgen für erste Sitzung und Wiederverbindung; fehlende Zertifikatsidentität führt zu einem expliziten Ergebnis `credentialsRequired`, niemals zu vorgetäuschtem Erfolg.
3. Deterministische Transcript-/Hash-/AES-/Signaturformat-Tests mit ausschließlich neu erzeugtem Testmaterial. ECDSA-Signaturen durch Verifikation vergleichen, nicht zufällige Signaturbytes als konstant voraussetzen.
4. Nach geklärter Backend-/Lizenzwahl: mathematische J-PAKE-Tests gegen unabhängige Referenz, einschließlich falschem Passwort, ungültigem Punkt, Punkt im Unendlichen und verworfenen Beweisen.
5. Kein echter BLE-Adapter und keine Freigabe des Mac-Hardware-Gates, bevor Ressourcenrechte, Erstkopplung und Wiederverbindung getrennt nachgewiesen sind.

Dieses erste Modul wäre ein überprüfbarer Fortschritt zum Standalone-Ziel. Ein erfolgreicher Parser- oder Kryptotest darf weiterhin nicht als funktionierende G7-Kopplung ausgegeben werden.
