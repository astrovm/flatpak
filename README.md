# astrovm Flatpak repository

**Install and update astrovm's apps with Flatpak.**

The repository for apps published by [astrovm](https://github.com/astrovm), served from `https://flatpak.4st.li/`.

## Apps

- [Adventure Mods](https://flatpak.4st.li/apps/io.github.astrovm.AdventureMods/install/)
- [PkgDeck](https://flatpak.4st.li/apps/io.github.astrovm.PkgDeck/install/)

This repo also builds unofficial **balenaEtcher 2.1.7** (x86_64) and
**Ventoy 1.1.17** (x86_64 and aarch64). See [the build and host bridge notes](packages/README.md).
These tools require host administrator access for disk operations.

## ⬇️ Install

Open an app's install page above. Each one also has a `.flatpakref` file.

Updates come through Flatpak as usual:

```sh
flatpak update
```

<details>
<summary><b>Add the repository by hand</b></summary>

```sh
flatpak remote-add --if-not-exists astrovm https://flatpak.4st.li/astrovm.flatpakrepo
```

</details>

<details>
<summary><b>Publishing</b></summary>

[`apps.json`](apps.json) lists the apps. It drives publishing, verification, health checks and the website.

The website shows `assets/apps/<app-id>/icon.svg` and `screenshot.webp` when an app has them.
Files in `static/` (the cat, favicon, and the Nunito and Fira Code fonts) are copied to the site as they are.

### How it works

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

Etcher and Ventoy use the separate **Build USB tools** workflow because their
upstream releases do not contain Flatpak bundles. Its manual **publish** option
builds both pinned releases, imports them with the existing signing key, and
verifies the complete repository before updating `gh-pages`.

The publishing workflow:

1. accepts only repositories registered in `apps.json`;
2. validates the request and immutable GitHub release;
3. verifies bundle names, digests, architectures, and application refs;
4. imports and signs the bundles without removing other registered apps;
5. regenerates repository metadata, app installers, and the website;
6. verifies the finished repository with a fresh Flatpak client;
7. replaces `gh-pages` with the generated snapshot.

Website changes don't wait for a release. When `templates/`, `static/`,
`assets/` or the site scripts change on `main`, the **Refresh website**
workflow rebuilds the pages on `gh-pages` and keeps the repository as it is.

Repeated dispatches for the same release are safe. If nothing changes, the
workflow exits without creating another commit. A daily health workflow checks
every registered app and architecture.

### Add an app

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

Use versioned release bundles such as `Example-v1.2.3-aarch64.flatpak`.
The publisher selects exactly one bundle per architecture using the release
tag and verifies its release digest and Flatpak ref. Previously published
unversioned bundles remain publishable. The first publication adds the app to
the existing OSTree repository and generates its website card, install page,
and `.flatpakref` file.

Removing an application from `apps.json` requires a separate repository
migration because unregistered refs are intentionally rejected.

### Secrets

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

### GitHub Pages

After the first successful publication creates `gh-pages`:

1. Open **Settings → Pages**.
2. Select **Deploy from a branch**.
3. Select `gh-pages` and `/(root)`.
4. Set the custom domain to `flatpak.4st.li` and enable HTTPS.
5. Configure the DNS record `flatpak.4st.li CNAME astrovm.github.io`.

The workflow also writes `.nojekyll` and `CNAME` to the publishing branch.

### Publish by hand

Run the workflow with any repository registered in `apps.json`:

```sh
gh workflow run publish.yml \
  --repo astrovm/flatpak \
  --field repository=astrovm/AdventureMods \
  --field tag=v0.3.12
```

Omit `tag` to publish the latest release.

### Recovery

If publication fails, fix the release or this repository and rerun the
workflow. Immutable releases cannot be edited, so incorrect assets require a
new release tag. Do not bypass digest, ref, OSTree, or Flatpak verification.

To roll back an application, run the workflow for that repository with its last
known-good immutable release tag.

### Signing-key recovery

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

</details>
