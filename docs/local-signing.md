# Local signing certificate (one time, per Mac)

macOS remembers privacy permissions (Microphone, System Audio Recording) per
app *identity*. An ad-hoc signed build's identity is the hash of that exact
build, so every rebuild looks like a new app and loses its permissions.
Signing with a stable certificate fixes that. `scripts/bundle.sh` uses a
certificate named **figg Local Signing** automatically when it exists. This
is only for building figg yourself.

## Create it

1. Open **Keychain Access** (Spotlight: "Keychain Access").
2. Menu **Keychain Access > Certificate Assistant > Create a Certificate…**
3. Name: `figg Local Signing`
4. Identity Type: **Self Signed Root**
5. Certificate Type: **Code Signing**
6. Click **Create**, then **Done**. It lands in your login keychain.

Check it:

```bash
security find-identity -p codesigning | grep "figg Local Signing"
```

## Then

```bash
scripts/bundle.sh
```

The output should end with `signed with 'figg Local Signing'`. Grant figg its
permissions once (System Settings > Privacy & Security > Microphone, and
Screen & System Audio Recording > System Audio Recording Only); they now
survive rebuilds. The first build signed this way may ask for your login
keychain password so codesign can use the key. Choose **Always Allow**.
