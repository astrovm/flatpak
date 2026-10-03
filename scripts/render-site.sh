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

validate_app_registry
# Validate the argument as given: resolving it first would follow symbolic links.
validate_output_directory "$2" "$repository_root"
output_directory=$(realpath --canonicalize-missing -- "$2")

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

# Optional artwork lives in assets/apps/<app-id>/: icon.svg and screenshot.webp.
copy_app_assets()
{
  local app_id=$1
  local asset_directory=$repository_root/assets/apps/$app_id

  mkdir -p "$output_directory/apps/$app_id"
  if [ -d "$asset_directory" ]; then
    cp -R "$asset_directory/." "$output_directory/apps/$app_id/"
  fi
}

render_app_icon()
{
  local app_id=$1
  local class_name=$2

  if [ -f "$output_directory/apps/$app_id/icon.svg" ]; then
    printf '<img class="%s" src="/apps/%s/icon.svg" alt="">' "$class_name" "$app_id"
  else
    printf '<span class="%s app-icon-fallback" aria-hidden="true"></span>' "$class_name"
  fi
}

render_app_screenshot()
{
  local app_id=$1
  local app_name=$2
  local class_name=$3

  if [ -f "$output_directory/apps/$app_id/screenshot.webp" ]; then
    printf '<div class="%s"><img src="/apps/%s/screenshot.webp" alt="%s screenshot"></div>' \
      "$class_name" "$app_id" "$app_name"
  fi
}

render_app_card()
{
  local repository=$1
  local app_id app_name app_summary app_icon app_screenshot

  app_id=$(app_value "$repository" id)
  app_name=$(app_html_value "$repository" name)
  app_summary=$(app_html_value "$repository" summary)
  app_icon=$(render_app_icon "$app_id" "app-icon")
  app_screenshot=$(render_app_screenshot "$app_id" "$app_name" "app-shot")

  cat <<EOF
          <a class="app-card" href="/apps/$app_id/install/">
            $app_screenshot
            <div class="app-card-body">
              $app_icon
              <div class="app-card-text">
                <h2>$app_name</h2>
                <p>$app_summary</p>
              </div>
              <span class="app-card-cta">install</span>
            </div>
          </a>
EOF
}

render_index()
{
  local line repository
  local -a repositories template_lines

  mapfile -t repositories < <(app_repositories)
  mapfile -t template_lines < "$repository_root/templates/index.html"
  for line in "${template_lines[@]}"; do
    if [ "$line" = "          <!-- APP_CARDS -->" ]; then
      for repository in "${repositories[@]}"; do
        render_app_card "$repository"
      done
    else
      line=${line//@STYLES_VERSION@/$stylesheet_version}
      printf '%s\n' "$line"
    fi
  done
}

render_app_files()
{
  local repository=$1
  local app_id app_branch app_name app_summary runtime_repository
  local app_icon app_screenshot install_directory

  app_id=$(app_value "$repository" id)
  app_branch=$(app_value "$repository" branch)
  app_name=$(app_value "$repository" name)
  app_summary=$(app_value "$repository" summary)
  runtime_repository=$(app_value "$repository" runtime_repository)

  copy_app_assets "$app_id"
  app_icon=$(render_app_icon "$app_id" "app-icon app-icon-large")
  app_screenshot=$(render_app_screenshot "$app_id" "$(app_html_value "$repository" name)" "app-screenshot")

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
    -e "s|@APP_ICON@|$(escape_sed_replacement "$app_icon")|g" \
    -e "s|@APP_SCREENSHOT@|$(escape_sed_replacement "$app_screenshot")|g" \
    -e "s|@REPOSITORY_URL@|$(escape_sed_replacement "https://github.com/$repository")|g" \
    -e "s|@STYLES_VERSION@|$stylesheet_version|g" \
    "$repository_root/templates/app-install.html" \
    > "$install_directory/index.html"
}

sed "s|@GPG_KEY@|$(escape_sed_replacement "$public_key")|" \
  "$repository_root/templates/astrovm.flatpakrepo.in" \
  > "$output_directory/astrovm.flatpakrepo"
cp "$public_key_file" "$output_directory/astrovm.gpg"
cp "$stylesheet_file" "$output_directory/styles.css"
cp -R "$repository_root/static/." "$output_directory/"

while IFS= read -r repository; do
  render_app_files "$repository"
done < <(app_repositories)
render_index > "$output_directory/index.html"

printf '%s\n' 'flatpak.4st.li' > "$output_directory/CNAME"
touch "$output_directory/.nojekyll"
