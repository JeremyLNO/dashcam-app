#!/usr/bin/env python3
"""Prévient avant que le certificat APNs de Dashcam Pocket n'expire.

Le push tourne sur un certificat `.p12` — un choix par défaut, pas un choix voulu :
la clé `.p8` qui ne périme jamais ne peut pas être posée par l'API OneSignal, seulement
par le sélecteur de fichier du tableau de bord (cf. docs/PUSH.md). Un certificat qui
expire ne casse rien bruyamment : les notifications cessent simplement d'arriver, et
personne ne s'en aperçoit avant d'en attendre une.

Ne lit aucun secret et n'appelle aucun service : la date est dans le certificat, sur le
disque. Rend 0 s'il reste du temps, 1 s'il faut agir.

    python3 tools/check-apns-expiry.py [jours_d_alerte]
"""
import datetime
import os
import subprocess
import sys

CERTIFICAT = os.path.expanduser("~/.appstoreconnect/apns/dashcam-aps.pem")
CLE_P8 = os.path.expanduser("~/private_keys/AuthKey_226GZ743S5.p8")
ALERTE_JOURS = int(sys.argv[1]) if len(sys.argv) > 1 else 60


def expiration() -> datetime.datetime:
    sortie = subprocess.run(
        ["openssl", "x509", "-in", CERTIFICAT, "-noout", "-enddate"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    # notAfter=Oct 14 22:20:13 2027 GMT
    return datetime.datetime.strptime(sortie.split("=", 1)[1], "%b %d %H:%M:%S %Y %Z")


def main() -> int:
    if not os.path.exists(CERTIFICAT):
        print("certificat absent — le push est peut-être déjà passé sur la clé .p8 ; "
              "si c'est le cas, cette tâche n'a plus lieu d'être")
        return 0

    reste = (expiration() - datetime.datetime.utcnow()).days
    if reste > ALERTE_JOURS:
        print(f"certificat APNs valide encore {reste} jours — rien à faire")
        return 0

    print(f"⚠️ le certificat APNs de Dashcam Pocket expire dans {reste} jours.")
    print("Quand il expire, les notifications cessent d'arriver sans que rien ne le dise.")
    print("La parade durable est la clé, qui ne périme pas :")
    print(f"  {CLE_P8}")
    print("OneSignal ▸ Dashcam Pocket ▸ Settings ▸ Apple iOS ▸ Update Authentication ▸")
    print("  p8 Auth Key, Key ID 226GZ743S5, Team ID 2E6D4Q69QB, puis Save & Continue.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
