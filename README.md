# astrovm Flatpak repository

Official Flatpak repository for applications published by [astrovm](https://github.com/astrovm).

The repository is served from `https://flatpak.4st.li/` and currently publishes Adventure Mods.

## Install

[Install Adventure Mods](https://flatpak.4st.li/apps/io.github.astrovm.AdventureMods/install/), or use the terminal:

```sh
flatpak install https://flatpak.4st.li/io.github.astrovm.AdventureMods.flatpakref
```

Updates are installed through the normal Flatpak update flow:

```sh
flatpak update
```

<details>
<summary>Manual repository setup</summary>

```sh
flatpak remote-add --if-not-exists astrovm https://flatpak.4st.li/astrovm.flatpakrepo

flatpak install astrovm io.github.astrovm.AdventureMods
```

</details>

## Publishing

Application repositories publish signed `.flatpak` bundles in a GitHub release
and send a `publish-app` repository dispatch:

```json
{
  "event_type": "publish-app",
  "client_payload": {
    "repository": "astrovm/AdventureMods",
    "tag": "v0.3.12"
  }
}
```

The publishing workflow:

1. validates the request and immutable GitHub release;
2. verifies both bundle digests, architectures, and application refs;
3. imports and signs the bundles;
4. generates deltas, metadata, and installer pages;
5. verifies the finished repository with a fresh Flatpak client;
6. replaces `gh-pages` with the generated snapshot.

Repeated dispatches for the same release are safe. If nothing changes, the
workflow exits without creating another commit. A daily health workflow also
checks the live metadata and both published architectures.

## Required secrets

Configure these secrets in the `flatpak-signing` GitHub environment:

- `FLATPAK_GPG_PRIVATE_KEY`: ASCII-armored private key for the dedicated
  unencrypted signing key.
- `FLATPAK_GPG_KEY_ID`: full fingerprint of that key.

The private key is imported only into a temporary GnuPG home. Generated
installer files contain only the public key.

The environment can optionally require reviewers when every repository
publication should have a human approval.

In Adventure Mods, configure `FLATPAK_REPO_TOKEN` as a fine-grained token scoped
only to `astrovm/flatpak` with **Contents: Read and write**.

## GitHub Pages setup

After the first successful publication creates `gh-pages`:

1. Open **Settings → Pages**.
2. Select **Deploy from a branch**.
3. Select `gh-pages` and `/(root)`.
4. Set the custom domain to `flatpak.4st.li` and enable HTTPS.
5. Configure the DNS record `flatpak.4st.li CNAME astrovm.github.io`.

The workflow also writes `.nojekyll` and `CNAME` to the publishing branch.

## Manual publication

The workflow can also be run manually:

```sh
gh workflow run publish.yml \
  --repo astrovm/flatpak \
  --field repository=astrovm/AdventureMods \
  --field tag=v0.3.12
```

Omit `tag` to publish the latest release. Only repositories explicitly allowed
by `scripts/publish.sh` can be published.

## Recovery

If publication fails, fix the release or this repository and rerun the
workflow. Immutable releases cannot be edited, so incorrect assets require a
new release tag. Do not bypass digest, ref, OSTree, or Flatpak verification.

To roll back Adventure Mods, run the workflow with the last known-good immutable
release tag.

## Signing-key recovery

Flatpak clients trust the configured repository key. Replacing it without
updating clients prevents future updates.

If the signing key is lost or compromised:

1. Pause publication and remove the compromised secret.
2. Create a dedicated replacement key.
3. Update `FLATPAK_GPG_PRIVATE_KEY` and `FLATPAK_GPG_KEY_ID`.
4. Publish the current release.
5. Ask existing users to import the replacement public key:

   ```sh
   curl --fail --output astrovm.gpg https://flatpak.4st.li/astrovm.gpg
   flatpak remote-modify --gpg-import=astrovm.gpg astrovm
   ```

Keep an encrypted offline backup of the signing key. Never store a private key
in this repository, workflow logs, release assets, or artifacts.
