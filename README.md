# astrovm Flatpak repository

Official Flatpak repository for applications published by [astrovm](https://github.com/astrovm).

The repository is served from `https://flatpak.4st.li/`. Applications are
configured in [`apps.json`](apps.json), which is the source of truth for
publishing, verification, health checks, and the generated website.

## Applications

- [Adventure Mods](https://flatpak.4st.li/apps/io.github.astrovm.AdventureMods/install/)

Each application has a generated install page and `.flatpakref` file.

Updates are installed through the normal Flatpak update flow:

```sh
flatpak update
```

<details>
<summary>Manual repository setup</summary>

```sh
flatpak remote-add --if-not-exists astrovm https://flatpak.4st.li/astrovm.flatpakrepo
```

</details>

## Publishing

Each registered application repository publishes one `.flatpak` bundle per
configured architecture in an immutable GitHub release, then sends a
`publish-app` repository dispatch:

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

1. accepts only repositories registered in `apps.json`;
2. validates the request and immutable GitHub release;
3. verifies bundle names, digests, architectures, and application refs;
4. imports and signs the bundles without removing other registered apps;
5. regenerates repository metadata, app installers, and the website;
6. verifies the finished repository with a fresh Flatpak client;
7. replaces `gh-pages` with the generated snapshot.

Repeated dispatches for the same release are safe. If nothing changes, the
workflow exits without creating another commit. A daily health workflow checks
every registered app and architecture.

## Add an application

Add one object to `apps.json`:

```json
{
  "repository": "astrovm/Example",
  "id": "io.github.astrovm.Example",
  "name": "Example",
  "summary": "A short description.",
  "bundle_prefix": "Example",
  "branch": "master",
  "architectures": ["x86_64", "aarch64"],
  "runtime_repository": "https://dl.flathub.org/repo/flathub.flatpakrepo"
}
```

Release bundles must use the configured prefix and architecture, such as
`Example-aarch64.flatpak`. The first publication adds the app to the existing
OSTree repository and generates its website card, install page, and
`.flatpakref` file.

Removing an application from `apps.json` requires a separate repository
migration because unregistered refs are intentionally rejected.

## Required secrets

Configure these secrets in the `flatpak-signing` GitHub environment:

- `FLATPAK_GPG_PRIVATE_KEY`: ASCII-armored private key for the dedicated
  unencrypted signing key.
- `FLATPAK_GPG_KEY_ID`: full fingerprint of that key.

The private key is imported only into a temporary GnuPG home. Generated
installer files contain only the public key.

The environment can optionally require reviewers when every repository
publication should have a human approval.

Each application repository needs `FLATPAK_REPO_TOKEN`, a fine-grained token
scoped only to `astrovm/flatpak` with **Contents: Read and write**.

## GitHub Pages setup

After the first successful publication creates `gh-pages`:

1. Open **Settings → Pages**.
2. Select **Deploy from a branch**.
3. Select `gh-pages` and `/(root)`.
4. Set the custom domain to `flatpak.4st.li` and enable HTTPS.
5. Configure the DNS record `flatpak.4st.li CNAME astrovm.github.io`.

The workflow also writes `.nojekyll` and `CNAME` to the publishing branch.

## Manual publication

Run the workflow with any repository registered in `apps.json`:

```sh
gh workflow run publish.yml \
  --repo astrovm/flatpak \
  --field repository=astrovm/AdventureMods \
  --field tag=v0.3.12
```

Omit `tag` to publish the latest release.

## Recovery

If publication fails, fix the release or this repository and rerun the
workflow. Immutable releases cannot be edited, so incorrect assets require a
new release tag. Do not bypass digest, ref, OSTree, or Flatpak verification.

To roll back an application, run the workflow for that repository with its last
known-good immutable release tag.

## Signing-key recovery

Flatpak clients trust the configured repository key. Replacing it without
updating clients prevents future updates.

If the signing key is lost or compromised:

1. Pause publication and remove the compromised secret.
2. Create a dedicated replacement key.
3. Update `FLATPAK_GPG_PRIVATE_KEY` and `FLATPAK_GPG_KEY_ID`.
4. Publish a current application release.
5. Ask existing users to import the replacement public key:

   ```sh
   curl --fail --output astrovm.gpg https://flatpak.4st.li/astrovm.gpg
   flatpak remote-modify --gpg-import=astrovm.gpg astrovm
   ```

Keep an encrypted offline backup of the signing key. Never store a private key
in this repository, workflow logs, release assets, or artifacts.
