#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(realpath -- "$script_directory/..")
# shellcheck source=scripts/lib/publish-common.sh
source "$script_directory/lib/publish-common.sh"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <public-key-file> <output-directory>" >&2
  exit 2
fi

public_key_file=$(realpath -- "$1")
output_directory=$(realpath --canonicalize-missing -- "$2")

validate_app_registry
validate_output_directory "$output_directory" "$repository_root"

public_key=$(base64 --wrap=0 "$public_key_file")
if [ -z "$public_key" ]; then
  error "Public key is empty: $public_key_file"
  exit 1
fi

mkdir -p "$output_directory"

stylesheet_file=$repository_root/templates/styles.css
stylesheet_version=$(sha256sum "$stylesheet_file" | cut -c1-12)

escape_sed_replacement()
{
  # shellcheck disable=SC2001
  sed 's/[&|\\]/\\&/g' <<< "$1"
}

render_app_card()
{
  local repository=$1
  local app_id app_name app_summary

  app_id=$(app_value "$repository" id)
  app_name=$(app_html_value "$repository" name)
  app_summary=$(app_html_value "$repository" summary)

  cat <<EOF
          <a
            class="card app-card"
            href="/apps/$app_id/install/"
          >
            <div>
              <h2>$app_name</h2>
              <p>$app_summary</p>
            </div>
            <span class="app-card-arrow" aria-hidden="true">→</span>
          </a>
EOF
}

render_index()
{
  local line repository

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "          <!-- APP_CARDS -->" ]; then
      while IFS= read -r repository; do
        render_app_card "$repository"
      done < <(app_repositories)
    else
      line=${line//@STYLES_VERSION@/$stylesheet_version}
      printf '%s\n' "$line"
    fi
  done < "$repository_root/templates/index.html" \
    > "$output_directory/index.html"
}

render_app_files()
{
  local repository=$1
  local app_id app_branch app_name app_summary runtime_repository
  local app_arch_badges install_directory

  app_id=$(app_value "$repository" id)
  app_branch=$(app_value "$repository" branch)
  app_name=$(app_value "$repository" name)
  app_summary=$(app_value "$repository" summary)
  runtime_repository=$(app_value "$repository" runtime_repository)

  app_arch_badges=$(
    while IFS= read -r architecture; do
      printf '<span class="arch-badge">%s</span> ' "$architecture"
    done < <(app_architectures "$repository")
  )
  app_arch_badges=${app_arch_badges% }

  sed \
    -e "s|@APP_ID@|$(escape_sed_replacement "$app_id")|g" \
    -e "s|@APP_BRANCH@|$(escape_sed_replacement "$app_branch")|g" \
    -e "s|@APP_NAME@|$(escape_sed_replacement "$app_name")|g" \
    -e "s|@APP_SUMMARY@|$(escape_sed_replacement "$app_summary")|g" \
    -e "s|@RUNTIME_REPOSITORY@|$(escape_sed_replacement "$runtime_repository")|g" \
    -e "s|@GPG_KEY@|$(escape_sed_replacement "$public_key")|g" \
    "$repository_root/templates/app.flatpakref.in" \
    > "$output_directory/$app_id.flatpakref"

  install_directory=$output_directory/apps/$app_id/install
  mkdir -p "$install_directory"
  sed \
    -e "s|@APP_ID@|$(escape_sed_replacement "$app_id")|g" \
    -e "s|@APP_NAME@|$(escape_sed_replacement "$(app_html_value "$repository" name)")|g" \
    -e "s|@APP_SUMMARY@|$(escape_sed_replacement "$(app_html_value "$repository" summary)")|g" \
    -e "s|@APP_ARCH_BADGES@|$(escape_sed_replacement "$app_arch_badges")|g" \
    -e "s|@REPOSITORY_URL@|$(escape_sed_replacement "https://github.com/$repository")|g" \
    -e "s|@STYLES_VERSION@|$stylesheet_version|g" \
    "$repository_root/templates/app-install.html" \
    > "$install_directory/index.html"
}

sed "s|@GPG_KEY@|$(escape_sed_replacement "$public_key")|" \
  "$repository_root/templates/astrovm.flatpakrepo.in" \
  > "$output_directory/astrovm.flatpakrepo"
cp "$public_key_file" "$output_directory/astrovm.gpg"
render_index
cp "$stylesheet_file" "$output_directory/styles.css"

while IFS= read -r repository; do
  render_app_files "$repository"
done < <(app_repositories)

printf '%s\n' 'flatpak.4st.li' > "$output_directory/CNAME"
touch "$output_directory/.nojekyll"
