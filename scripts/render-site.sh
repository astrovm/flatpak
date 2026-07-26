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

escape_sed_replacement()
{
  # shellcheck disable=SC2001
  sed 's/[&|\\]/\\&/g' <<< "$1"
}

render_app_card()
{
  local repository=$1
  local app_id app_name app_summary repository_url

  app_id=$(app_value "$repository" id)
  app_name=$(app_html_value "$repository" name)
  app_summary=$(app_html_value "$repository" summary)
  repository_url=https://github.com/$repository

  cat <<EOF
          <article class="card app-card">
            <div>
              <div class="app-heading">
                <h2>$app_name</h2>
                <a class="github-link" href="$repository_url">
                  <svg
                    class="github-icon"
                    viewBox="0 0 24 24"
                    aria-hidden="true"
                  >
                    <path d="M10.226 17.284c-2.965-.36-5.054-2.493-5.054-5.256 0-1.123.404-2.336 1.078-3.144-.292-.741-.247-2.314.09-2.965.898-.112 2.111.36 2.83 1.01.853-.269 1.752-.404 2.853-.404 1.1 0 1.999.135 2.807.382.696-.629 1.932-1.1 2.83-.988.315.606.36 2.179.067 2.942.72.854 1.101 2 1.101 3.167 0 2.763-2.089 4.852-5.098 5.234.763.494 1.28 1.572 1.28 2.807v2.336c0 .674.561 1.056 1.235.786 4.066-1.55 7.255-5.615 7.255-10.646C23.5 6.188 18.334 1 11.978 1 5.62 1 .5 6.188.5 12.545c0 4.986 3.167 9.12 7.435 10.669.606.225 1.19-.18 1.19-.786V20.63a2.9 2.9 0 0 1-1.078.224c-1.483 0-2.359-.808-2.987-2.313-.247-.607-.517-.966-1.034-1.033-.27-.023-.359-.135-.359-.27 0-.27.45-.471.898-.471.652 0 1.213.404 1.797 1.235.45.651.921.943 1.483.943.561 0 .92-.202 1.437-.719.382-.381.674-.718.944-.943"/>
                  </svg>
                  <span>GitHub</span>
                </a>
              </div>
              <p>$app_summary</p>
            </div>
            <div class="actions">
              <a
                class="button button-primary"
                href="/apps/$app_id/install/"
              >
                Install $app_name
              </a>
              <a class="button" href="/$app_id.flatpakref">
                Download installer
              </a>
            </div>
          </article>
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
      printf '%s\n' "$line"
    fi
  done < "$repository_root/templates/index.html" \
    > "$output_directory/index.html"
}

render_app_files()
{
  local repository=$1
  local app_id app_branch app_name app_summary runtime_repository
  local install_directory

  app_id=$(app_value "$repository" id)
  app_branch=$(app_value "$repository" branch)
  app_name=$(app_value "$repository" name)
  app_summary=$(app_value "$repository" summary)
  runtime_repository=$(app_value "$repository" runtime_repository)

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
    -e "s|@REPOSITORY_URL@|$(escape_sed_replacement "https://github.com/$repository")|g" \
    "$repository_root/templates/app-install.html" \
    > "$install_directory/index.html"
}

sed "s|@GPG_KEY@|$(escape_sed_replacement "$public_key")|" \
  "$repository_root/templates/astrovm.flatpakrepo.in" \
  > "$output_directory/astrovm.flatpakrepo"
cp "$public_key_file" "$output_directory/astrovm.gpg"
render_index
cp "$repository_root/templates/styles.css" "$output_directory/styles.css"

while IFS= read -r repository; do
  render_app_files "$repository"
done < <(app_repositories)

printf '%s\n' 'flatpak.4st.li' > "$output_directory/CNAME"
touch "$output_directory/.nojekyll"
