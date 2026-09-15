# Push — OneSignal et APNs

L'app **Dashcam Pocket** = `386ceb76-981e-44cd-88bb-99b9742218f3`, organisation **Crazy Bee
Labs** (jamais l'organisation LNO, qui vit sur le même compte). Le SDK est *gaté par la
configuration* : `ONESIGNAL_APP_ID` vide dans le xcconfig et rien ne s'initialise, aucun jeton
n'est demandé, rien ne part.

## Ce qui tourne aujourd'hui

Un **certificat APNs `.p12`**, valable jusqu'au **15 octobre 2027**, fabriqué à la main :

```
~/.appstoreconnect/apns/dashcam-apns.csr   la demande
~/.appstoreconnect/apns/dashcam-apns.key   la clé privée
~/.appstoreconnect/apns/dashcam-aps.cer    le certificat d'Apple
~/.appstoreconnect/apns/dashcam-apns.p12   les deux réunis, mot de passe VIDE
```

⚠️ Un certificat expire ; une clé `.p8` non. `tools/check-apns-expiry.py` lit la date dans le
certificat lui-même — aucun secret, aucun appel réseau — et se tait tant qu'il reste plus de
60 jours. Une tâche planifiée mensuelle (`apns-expiry-dashcam`) l'exécute.

## La bascule vers la clé, quand elle se fera

`~/private_keys/AuthKey_226GZ743S5.p8` — Key ID `226GZ743S5`, Team ID `2E6D4Q69QB`, *Team
Scoped (all topics)*, environnement **Production**. Elle couvre toutes les apps du compte et
ne périme jamais.

⚠️ **Elle ne peut pas être posée par l'API.** Isolé champ par champ : `apns_key_id`,
`apns_team_id`, `apns_bundle_id`, `apns_env` et `name` passent en 200 sur
`PUT https://api.onesignal.com/apps/{id}` ; **`apns_p8` répond 400 avec `{"errors":[]}`**,
seul ou accompagné, en PEM comme en base64, avant comme après avoir tenté de vider le
certificat. Le tableau de bord la pose par un sélecteur de fichier natif, que rien ne pilote
depuis un navigateur, et sa sauvegarde passe par une action serveur Next.js qu'on ne peut pas
rejouer.

Le chemin : OneSignal ▸ Dashcam Pocket ▸ Settings ▸ Apple iOS ▸ **Update Authentication** ▸
*p8 Auth Key* ▸ Key ID, Team ID, fichier ▸ **Save & Continue**. ⚠️ Sans le *Save*, la page
repart à zéro sans rien dire — un fichier choisi mais non enregistré ne laisse aucune trace.

## Les deux clés d'API, et laquelle pour quoi

| Pour | Clé | Appel |
|---|---|---|
| Écrire la configuration d'une app | organisation (*Organizations ▸ Keys & IDs*) | `PUT /apps/{id}` |
| Envoyer une notification | app (*App ▸ Settings ▸ Keys & IDs*) | `POST /notifications` |

En-tête `Authorization: Key <clé>`. Se tromper coûte un **401** qui ne dit pas laquelle
manque. Les clés ne sont montrées **qu'une fois** : les copier dans le presse-papier et les
consommer par `KEY=$(pbpaste)` évite de les écrire où que ce soit.

## Vérifier un envoi, pas seulement son acceptation

`POST /notifications` répond 200 avec un identifiant sans rien promettre.

```bash
curl -s "https://api.onesignal.com/notifications/<id>?app_id=<app>" \
  -H "Authorization: Key $(pbpaste)" | python3 -m json.tool | grep -E 'successful|failed'
```

`successful: 1` est la seule preuve qu'un téléphone a reçu quelque chose.
