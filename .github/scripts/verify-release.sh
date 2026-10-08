#!/usr/bin/env bash
# verify-release.sh — the release-integrity half of this tap's PR checks.
#
#   .github/scripts/verify-release.sh <formula> [<base-formula>]
#
# Proves that <formula> points `brew install dome` at a published
# dome-systems/releases release, and nowhere else:
#
#   1. Every source in the formula is a literal `url "…"` followed by its
#      `sha256 "…"`. Any other source declaration (mirror, resource, patch, head,
#      a url with options) fails, so nothing can sit outside the checks below.
#   2. The URLs are exactly the four release archives for the formula's version,
#      dome_<v>_{darwin,linux}_{amd64,arm64}.tar.gz under
#      github.com/dome-systems/releases/releases/download/v<v>/ — no other host,
#      no other release, no platform missing.
#   3. Release v<v> exists and is published. A draft's assets 404 for customers,
#      which is how v0.2.0 broke `brew install dome`. An Actions token cannot see
#      a draft at all, so in CI a draft reads as missing.
#   4. Each archive downloads without credentials, and its sha256 matches both
#      the formula and the release's checksums.txt.
#   5. Against <base-formula> (main's copy), when given: the version does not go
#      backwards unless ALLOW_DOWNGRADE=true (the PR's `rollback` label), and a
#      version that is already on main keeps its exact checksums — a published
#      version's archives are never swapped in place.
#
# The per-platform half — brew on each real OS/arch resolves that platform's
# archive, installs it, and the binary runs — is the `install` job in
# .github/workflows/formula.yml. Needs bash, curl, jq, and gh (GH_TOKEN in CI).
set -euo pipefail

RELEASES_REPO=dome-systems/releases
PLATFORMS="darwin_amd64 darwin_arm64 linux_amd64 linux_arm64"

errors=0
err() { echo "::error::$*" >&2; errors=$((errors + 1)); }
die() { echo "::error::$*" >&2; exit 1; }
ok()  { echo "  ok  $*"; }

# parse <formula> → "version <v>", then one "source <url> <sha256>" line per
# url/sha256 pair, in file order. Dies on anything else that declares a source.
parse() {
  local file=$1 line n=0 url="" version="" versions=0
  local re_version='^[[:space:]]*version[[:space:]]+"([^"]+)"[[:space:]]*$'
  local re_url='^[[:space:]]*url[[:space:]]+"([^"]+)"[[:space:]]*$'
  local re_sha='^[[:space:]]*sha256[[:space:]]+"([0-9a-f]{64})"[[:space:]]*$'
  local re_source='^[[:space:]]*(url|sha256|mirror|resource|patch|head|stable|bottle|version)([[:space:](]|$)'
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    if [[ $line =~ $re_version ]]; then
      version=${BASH_REMATCH[1]}
      versions=$((versions + 1))
    elif [[ $line =~ $re_url ]]; then
      [[ -z $url ]] || die "$file:$n: url with no sha256 after it: $url"
      url=${BASH_REMATCH[1]}
    elif [[ $line =~ $re_sha ]]; then
      [[ -n $url ]] || die "$file:$n: sha256 with no url before it"
      echo "source $url ${BASH_REMATCH[1]}"
      url=""
    elif [[ $line =~ $re_source ]]; then
      die "$file:$n: only literal url \"…\" / sha256 \"…\" pairs may declare a source, found: $line"
    fi
  done <"$file"
  [[ -z $url ]] || die "$file: url with no sha256 after it: $url"
  [[ $versions == 1 ]] || die "$file: expected exactly one version line, found $versions"
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
    || die "$file: version \"$version\" is not X.Y.Z or X.Y.Z-prerelease"
  echo "version $version"
}

# field <parsed> version → the version; field <parsed> sha <url> → that url's sha256(s).
field() {
  case $2 in
    version) awk '$1 == "version" { print $2 }' <<<"$1" ;;
    sha) awk -v u="$3" '$1 == "source" && $2 == u { print $3 }' <<<"$1" ;;
  esac
}

# vercmp <a> <b> → -1, 0 or 1 by semver precedence (X.Y.Z with an optional -prerelease).
vercmp() {
  local ap="" bp="" i
  local -a x y
  [[ $1 == *-* ]] && ap=${1#*-}
  [[ $2 == *-* ]] && bp=${2#*-}
  IFS=. read -r -a x <<<"${1%%-*}"
  IFS=. read -r -a y <<<"${2%%-*}"
  for i in 0 1 2; do
    if ((10#${x[i]} < 10#${y[i]})); then echo -1; return; fi
    if ((10#${x[i]} > 10#${y[i]})); then echo 1; return; fi
  done
  if [[ $ap == "$bp" ]]; then echo 0; return; fi
  if [[ -z $ap ]]; then echo 1; return; fi # a release outranks its own prereleases
  if [[ -z $bp ]]; then echo -1; return; fi
  if [[ $(printf '%s\n%s\n' "$ap" "$bp" | sort -V | head -n 1) == "$ap" ]]; then echo -1; else echo 1; fi
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{ print $1 }'
}

formula=${1:?usage: verify-release.sh <formula> [<base-formula>]}
base=${2:-}

# 1. Every source is a literal url/sha256 pair.
parsed=$(parse "$formula")
version=$(field "$parsed" version)
download="https://github.com/$RELEASES_REPO/releases/download/v$version"
echo "Formula $formula: dome v$version"

# 2. Exactly the four archives of release v<version>, each declared once.
expected=""
for p in $PLATFORMS; do expected+="$download/dome_${version}_$p.tar.gz"$'\n'; done
while read -r kind u _; do
  [[ $kind == source ]] || continue
  grep -qxF "$u" <<<"$expected" || die "formula points outside release v$version of $RELEASES_REPO: $u"
done <<<"$parsed"
for p in $PLATFORMS; do
  n=$(field "$parsed" sha "$download/dome_${version}_$p.tar.gz" | wc -l | tr -d ' ')
  [[ $n == 1 ]] || die "formula declares the $p archive $n times, want exactly once"
done
ok "sources are the 4 archives of $RELEASES_REPO v$version"

# 3. The release exists and is published.
release=$(gh release view "v$version" --repo "$RELEASES_REPO" --json isDraft,isPrerelease,url 2>/dev/null) \
  || die "no published release v$version in $RELEASES_REPO — it is missing or still a draft, and a draft's assets 404 for customers"
[[ $(jq -r .isDraft <<<"$release") == false ]] \
  || die "release v$version is still a draft — publish it before pointing the tap at it"
if [[ $(jq -r .isPrerelease <<<"$release") == true ]]; then echo "::notice::v$version is a prerelease"; fi
ok "release published: $(jq -r .url <<<"$release")"

# 4. Each archive downloads without credentials and matches the formula and checksums.txt.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$download/checksums.txt" \
  || die "checksums.txt for v$version is not downloadable without credentials"
for p in $PLATFORMS; do
  name="dome_${version}_$p.tar.gz"
  want=$(field "$parsed" sha "$download/$name")
  listed=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$tmp/checksums.txt")
  if ! curl -fsSL --retry 3 -o "$tmp/$name" "$download/$name"; then
    err "$name is not downloadable without credentials"
    continue
  fi
  got=$(sha256 "$tmp/$name")
  if [[ -z $listed ]]; then
    err "$name is not listed in the release's checksums.txt"
  elif [[ $got != "$listed" ]]; then
    err "$name downloads with sha256 $got, but checksums.txt lists $listed"
  elif [[ $got != "$want" ]]; then
    err "$name: the formula's sha256 $want does not match the archive ($got)"
  else
    ok "$name  $got"
  fi
done

# 5. Against main: no silent downgrade, and a published version's archives never change.
if [[ -n $base ]]; then
  base_parsed=$(parse "$base")
  base_version=$(field "$base_parsed" version)
  case $(vercmp "$version" "$base_version") in
    1) ok "upgrade from main's v$base_version" ;;
    -1)
      if [[ ${ALLOW_DOWNGRADE:-false} == true ]]; then
        echo "::notice::rolling back from main's v$base_version to v$version (rollback label)"
      else
        err "v$version is older than main's v$base_version — if this rollback is deliberate, add the 'rollback' label to the PR"
      fi
      ;;
    0)
      changed=0
      for p in $PLATFORMS; do
        u="$download/dome_${version}_$p.tar.gz"
        before=$(field "$base_parsed" sha "$u")
        after=$(field "$parsed" sha "$u")
        if [[ $before != "$after" ]]; then
          err "v$version is already on main with sha256 ${before:-<none>} for $p, this PR has $after — a published version's archives must not change; release a new version instead"
          changed=1
        fi
      done
      if ((changed == 0)); then ok "same version as main, checksums unchanged"; fi
      ;;
  esac
fi

if ((errors > 0)); then
  echo "::error::$errors check(s) failed for dome v$version"
  exit 1
fi
echo "dome v$version: formula, release, and archives agree."
