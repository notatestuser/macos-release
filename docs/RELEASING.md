# One-time signing setup (per Apple Developer team)

Do this once per team. The cert + key are team-wide and sign every app under that team.
Placeholders: `<TEAM_ID>` = your 10-char Apple team id, `<owner>/<app-repo>` = each app
repo, `<signing-dir>` = a local folder outside any repo (e.g. `~/Developer/apple-signing/`).

## 1. Developer ID Application certificate

Generate a private key + CSR locally (the key never leaves your machine, never commit it):

```bash
mkdir -p <signing-dir> && cd <signing-dir>
openssl genrsa -out DeveloperID.key 2048
openssl req -new -key DeveloperID.key -out DeveloperID.csr \
  -subj "/CN=Developer ID Application/O=<your org>/C=<CC>"
```

1. developer.apple.com/account → switch to the target team (`<TEAM_ID>`).
2. Certificates, IDs & Profiles → **Certificates** → ＋ → **Developer ID Application**.
3. Upload `DeveloperID.csr` → Download the issued `.cer`.
4. Build the importable `.p12` (pairs the cert with the local private key; include
   Apple's *Developer ID — G2* intermediate from https://www.apple.com/certificateauthority/
   for a complete CI chain).

   > **Use `-legacy`.** OpenSSL 3 defaults to a SHA-256 PKCS#12 MAC that macOS
   > `security import` (used by CI) cannot read — it fails with the misleading
   > `MAC verification failed during PKCS12 import (wrong password?)`. `-legacy`
   > writes the SHA-1-MAC format `security` accepts.

   ```bash
   cd <signing-dir>
   openssl x509 -inform DER -in developerID_application.cer -out leaf.pem
   openssl x509 -inform DER -in DeveloperIDG2CA.cer -out interm.pem
   openssl pkcs12 -export -legacy -inkey DeveloperID.key -in leaf.pem -certfile interm.pem \
     -out DeveloperID.p12 -name "Developer ID Application" -passout pass:CHOOSE_A_PASSWORD
   ```

   Verify `security import` accepts it before pushing secrets:
   ```bash
   KC=/tmp/v.keychain-db; security create-keychain -p t "$KC"; security unlock-keychain -p t "$KC"
   security import DeveloperID.p12 -k "$KC" -P CHOOSE_A_PASSWORD -T /usr/bin/codesign && echo OK
   security delete-keychain "$KC"
   ```

   Keep `DeveloperID.p12` + its password safe. This is the CI signing secret.

## 2. App Store Connect API key (notarization)

1. appstoreconnect.apple.com → Users and Access → **Integrations → App Store Connect API**.
2. Generate an **Individual key**, role **Developer** → download `AuthKey_XXXXX.p8` (one-time).
3. Record the **Key ID** and the **Issuer ID** (top of the Keys page).

`notarytool` uses these three (`.p8` + key id + issuer id) — no Apple-ID password, no 2FA in CI.

## 3. Push secrets into every app repo

Each repo holds its own copy of the secrets (or use org-level secrets if the repos live
in a GitHub org). From a shell with `gh` authed:

```bash
cd <signing-dir>
base64 -i DeveloperID.p12   -o devid.p12.b64
base64 -i AuthKey_XXXXX.p8  -o notary.p8.b64

P12_PW='CHOOSE_A_PASSWORD'
KEY_ID='XXXXX'
ISSUER='yyyyyyyy-....'

for repo in <owner>/<app-repo> <owner>/<another-app-repo>; do
  gh secret set DEVID_CERT_P12_BASE64    --repo "$repo" < devid.p12.b64
  gh secret set DEVID_CERT_PASSWORD      --repo "$repo" --body "$P12_PW"
  gh secret set NOTARY_API_KEY_P8_BASE64 --repo "$repo" < notary.p8.b64
  gh secret set NOTARY_API_KEY_ID        --repo "$repo" --body "$KEY_ID"
  gh secret set NOTARY_API_ISSUER_ID     --repo "$repo" --body "$ISSUER"
done

rm -f devid.p12.b64 notary.p8.b64
```

> Each caller workflow also passes its `team-id` (the team whose cert is loaded above).
> Apps on different teams use different cert/key secrets + their own `team-id`.

## 4. First release

```bash
# in the app repo, on the default branch, with a clean tree:
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0          # → CI builds, signs, notarizes, publishes the .dmg
```

Verify the published dmg on any Mac:

```bash
xcrun stapler validate <dmg-name>-v1.0.0.dmg
spctl -a -t open --context context:primary-signature -vv <dmg-name>-v1.0.0.dmg   # → "accepted, source=Notarized Developer ID"
```

## Rotating the cert

Re-run §1 + §3 (push new `DEVID_CERT_*` secrets to all repos). Old notarized builds stay valid.
