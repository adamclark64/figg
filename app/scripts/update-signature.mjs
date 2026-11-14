// The release signature the in-app updater checks (UpdateVerifier in
// Sources/FiggUpdate): Ed25519 over the dmg's bytes. Shared by the publish
// step, which signs, and make-update-key.mjs, which makes the key.
//
// Nothing here prints, logs or writes the private key, and no error message
// carries any part of it.
import { createPrivateKey, createPublicKey, sign, verify } from "node:crypto";
import { readFile } from "node:fs/promises";

/** Where the app lists the public keys it trusts. */
const VERIFIER = new URL("../Sources/FiggUpdate/UpdateVerifier.swift", import.meta.url);

/** Reads the private key from its PEM text (what the secret holds). */
export function loadSigningKey(pem) {
  let key;
  try {
    key = createPrivateKey(pem);
  } catch {
    // Not the underlying error: keep anything derived from the input out of the log.
    throw new Error("the signing key is not a readable private key (expected the PEM that make-update-key.mjs stored)");
  }
  if (key.asymmetricKeyType !== "ed25519") throw new Error("the signing key is not an Ed25519 key");
  return key;
}

/** Base64 of the raw 32-byte public key, the form UpdateVerifier.releaseKeys lists. */
export function publicKeyOf(privateKey) {
  // An Ed25519 public key in DER is a fixed header followed by the 32 key bytes.
  return createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
}

/** Base64 signature over `bytes`, checked against the key's own public half before it is returned. */
export function signBytes(bytes, privateKey) {
  const signature = sign(null, bytes, privateKey);
  if (!verify(null, bytes, createPublicKey(privateKey), signature)) {
    throw new Error("the signature just made does not verify");
  }
  return signature.toString("base64");
}

/** The public keys compiled into the app, read from the Swift source. */
export async function trustedKeys() {
  const source = await readFile(VERIFIER, "utf8");
  const list = source.match(/static let releaseKeys: \[String\] = \[([^\]]*)\]/);
  if (!list) throw new Error("could not find releaseKeys in Sources/FiggUpdate/UpdateVerifier.swift");
  return [...list[1].matchAll(/"([A-Za-z0-9+/=]+)"/g)].map((match) => match[1]);
}
