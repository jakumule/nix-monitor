# Filters `dix diff --output=json` of two .drv closures down to real package version
# changes. Shared by diff-flake-update.sh and check-system-sync.sh.
# Build-time artifacts that show up in a .drv closure but are not packages.
def noise: test("\\.(tar(\\.[a-z0-9]+)?|tgz|tbz2?|txz|zip|7z|gem|whl|crate|jar|patch|diff|json|md|sh|nix|deb|rpm|AppImage)(\\?.*)?$|(^|[-_])(fish|bash|zsh)?-?completions$|-vendor(-staging)?$|-binlore$|-go-modules$|-source$|-src$|-gsettings-schemas$|-x86_64-[a-z-]+$|-aarch64-[a-z-]+$"; "i");
def hashname: test("^[0-9a-df-np-sv-z]{32}-");
def real: . != null and . != "" and (noise | not);

def changes:
  [ .versions[]
    | if .kind == "changed" then
        select((.old.name | real) and (.new.name | real)) | {old: .old.name, new: .new.name}
      elif .kind == "added" then
        select(.version.name | real) | {old: null, new: .version.name}
      elif .kind == "removed" then
        select(.version.name | real) | {old: .version.name, new: null}
      else empty end
  ] | unique;

# dix "Mixed" = some versions up, some down/removed; it is still an update of the package.
def status:
  if .status == "Mixed" then "upgraded" else (.status | ascii_downcase) end;

[ .diffs[]
  | select((.name | noise | not) and (.name | hashname | not))
  | {name, status: status, changes: changes}
  # Real packages carry a version; versionless leftovers are build-input fragments.
  | select((.changes | length) > 0)
  | select(.status | IN("upgraded", "downgraded", "added", "removed"))
] as $pkgs
| {
    status: "ok",
    packages: $pkgs,
    counts: (reduce ("upgraded", "downgraded", "added", "removed") as $s
               ({}; .[$s] = ([$pkgs[] | select(.status == $s)] | length))),
    paths: {old: .paths.old, new: .paths.new},
    sizeOld: .size_old,
    sizeNew: .size_new
  }
