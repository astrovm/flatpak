# astrovm Flatpak repository

Official Flatpak repository for applications published by [astrovm](https://github.com/astrovm).

The repository is served from `https://flatpak.4st.li/` and currently publishes Adventure Mods.

## Install

Install Adventure Mods directly from its Flatpak reference:

```sh
flatpak install --user \
  https://flatpak.4st.li/io.github.astrovm.AdventureMods.flatpakref
```

Updates are installed through the normal Flatpak update flow:

```sh
flatpak update
```

<details>
<summary>Manual repository setup</summary>

```sh
flatpak remote-add --if-not-exists --user astrovm \
  https://flatpak.4st.li/astrovm.flatpakrepo

flatpak install --user astrovm io.github.astrovm.AdventureMods
```

</details>

## Publishing

Application repositories publish signed `.flatpak` bundles in a GitHub release and send a `publish-app` repository dispatch containing:

```json
{
  "event_type": "publish-app",
  "client_payload": {
    "repository": "astrovm/AdventureMods",
    "tag": "v0.3.10"
  }
}
```

The publishing workflow:

1. validates the source repository and release tag;
2. downloads all `.flatpak` assets from the release;
3. imports them into the persistent OSTree repository on `gh-pages`;
4. signs commits and repository metadata with the dedicated Flatpak GPG key;
5. generates static deltas and keeps the three previous revisions of each ref;
6. generates the repository file, Adventure Mods installer file, landing page, and custom-domain files;
7. replaces `gh-pages` with one generated snapshot of the updated repository.

The publishing branch is intentionally rewritten on each update. This preserves the current OSTree repository and its retained revisions without keeping pruned objects forever in Git history.

Repeated dispatches for the same release are safe. If nothing changes, the workflow exits without creating another commit.

## Required secrets

Configure these repository secrets before publishing:

- `FLATPAK_GPG_PRIVATE_KEY`: ASCII-armored private key for a dedicated, unencrypted signing key.
- `FLATPAK_GPG_KEY_ID`: full fingerprint of that key.

The private key is imported only into a temporary GnuPG home on the runner. The generated `.flatpakrepo` and `.flatpakref` files contain only the public key.

In the Adventure Mods repository, create `FLATPAK_REPO_TOKEN` from a fine-grained personal access token scoped only to `astrovm/flatpak` with **Contents: Read and write**. GitHub requires that permission for repository dispatch events.

## GitHub Pages setup

After the first successful publication creates `gh-pages`:

1. Open **Settings → Pages**.
2. Select **Deploy from a branch**.
3. Select `gh-pages` and `/(root)`.
4. Set the custom domain to `flatpak.4st.li` and enable HTTPS.
5. Configure the DNS record `flatpak.4st.li CNAME astrovm.github.io`.

The workflow also writes `.nojekyll` and `CNAME` to the publishing branch.

## Manual publication

The workflow can also be run manually from the Actions tab. Supply the source repository and release tag. Only repositories explicitly allowed by `scripts/publish.sh` can be published.
