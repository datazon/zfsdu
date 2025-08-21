#!/usr/bin/env bash
# zfsdu.sh v3.4-color — more colorful ncdu-like ZFS TUI (Proxmox/OpenZFS)
# - Main list: Filesystems (sorted by 'used'). Optional -d focuses on level 1.
# - Enter/→ on filesystem: Volumes (depth 1) + snapshots of the FS (non-recursive)
# - Enter/→ on volume    : Snapshots of this volume (non-recursive) — FS remains open
# - Backspace/←           : collapse (Vol-Snaps → FS), further backspace exits
# - Spacebar              : mark/unmark (multi-select)
# - d                     : delete marked entries (with safety prompt)
# - r                     : toggle snapshot size (used ↔ referenced)
# - z                     : toggle 0B snapshots (only effective in MODE=used)
# - q                     : exit
#
#	Author: Florian Schermer
#	Email: florian.schermer@datazon.de
#	Github:https://github.com/datazon/zfsdu

set -euo pipefail
LC_ALL=C

DATASET=""
MODE="used"      # 'used' (Default) oder 'refer' (= referenced) — wirkt auf Snapshot-Anzeige
HIDE_ZERO=0      # 0 = Snapshots mit 0B used anzeigen (Default); 1 = ausblenden (nur MODE=used)
COLOR=1

# ---- Farb-/Theme-Einstellungen ---------------------------------------------
# ANSI-Wrapper
c() { if (( COLOR )); then printf "\033[%sm%s\033[0m" "$1" "$2"; else printf "%s" "$2"; fi; }

# Farbpalette (Zahlen = ANSI-Farbcodes)
COL_FS=36       # cyan
COL_VOL=34      # blue
COL_SNAP=35     # magenta
COL_NAME=97     # bright white
COL_NAME_FS_OPEN=92; COL_NAME_FS_OPEN_BOLD="1;92"
COL_ARROW=90    # grey
COL_DIM=90      # grey dim

# Größe -> Farbstufe
size_color() {
  local b="$1"
  local G=$(( 50*1024*1024*1024 ))      # 50 GiB
  local Y=$(( 200*1024*1024*1024 ))     # 200 GiB
  local R=$(( 1024*1024*1024*1024 ))    # 1 TiB
  if   (( b >= R )); then echo 91       # red
  elif (( b >= Y )); then echo 33       # yellow
  elif (( b >= G )); then echo 32       # green
  else echo 37                          # light grey
  fi
}

# fzf-Theme (dunkel, ncdu-ähnlich)
FZF_COLORS='fg:-1,bg:-1,hl:36,fg+:15,bg+:24,hl+:45,info:36,prompt:36,pointer:34,marker:220,spinner:36,header:36,border:240'

usage() {
  cat <<'EOF'
zfsdu.sh — "ncdu"-like single-window navigation for ZFS (with marking/deleting)

Display & Navigation:
  • Main list: Filesystems (sorted by "used") — all sizes are human-readable
  • Enter/→ on a filesystem: shows ONLY level-1 volumes below + snapshots of the filesystem
  • Enter/→ on a volume    : shows ONLY snapshots of that volume (filesystem remains open)
  • No recursion beyond level 1; snapshots appear only when pressing Enter.

Usage: zfsdu.sh [OPTIONS]
  -d DATASET     Focus on DATASET (shows DATASET + level-1 filesystems)
  -m MODE        'used' (default) or 'refer' (== referenced; for snapshot display size)
  --show-zero    (compatibility option) show 0B snapshots — default is already to show them
  --hide-zero    hide 0B snapshots (only effective in MODE=used)
  --no-color     Disable colors
  -h, --help     Help
Keys:
  ↑/↓              Move
  Enter/→          Open/close
  Backspace/←      Go back (collapse)   [in fzf: 'bspace']
  Spacebar         Mark/unmark (multi-select)
  d                Delete marked entries (with confirmation)
  r                Toggle snapshot display size (used ↔ referenced)
  z                Toggle 0B snapshots (only in MODE=used)
  q / ESC / Ctrl-C Exit
  Typing           Filter (fzf)

EOF
}

while (( $# )); do
  case "${1:-}" in
    -d) DATASET="${2:-}"; shift 2 ;;
    -m) MODE="${2:-}"; shift 2 ;;
    --show-zero) HIDE_ZERO=0; shift ;;  # Default ist sichtbar
    --hide-zero) HIDE_ZERO=1; shift ;;
    --no-color) COLOR=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 1 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
for ccc in zfs awk sort fzf; do
  have "$ccc" || { echo "Fehlt: $ccc" >&2; exit 1; }
done
[[ "$MODE" == "used" || "$MODE" == "refer" ]] || { echo "Ungültiger Modus: $MODE" >&2; exit 1; }

# Human readable (IEC: KiB, MiB, GiB, TiB, …)
hr() {
  awk -v n="$1" 'function hr(n,u,i){split("B KiB MiB GiB TiB PiB EiB ZiB YiB",u," ");
    i=1; while (n>=1024 && i<length(u)) { n/=1024; i++ } printf("%.1f %s", n, u[i]);}
    BEGIN{hr(n)}'
}

# Expansionszustände
EXPANDED_FS=""
EXPANDED_VOL=""

# Parent-Dataset (alles vor letztem '/')
parent_ds() {
  local x="$1"
  [[ "$x" == */* ]] && echo "${x%/*}" || echo "$x"
}

# Hauptliste bauen — Ausgabe:
# <sichtbar formatiert>\t<META>
# META: "FS|<fs-name>" oder "VOL|<vol-name>" oder "SNAP|<full-snapshot-name>"
build_list() {
  local rows=""

  if [[ -n "$DATASET" ]]; then
    rows="$(zfs list -Hp -r -d 1 -t filesystem -o name,used -- "$DATASET" 2>/dev/null || true)"
  else
    rows="$(zfs list -Hp -t filesystem -o name,used 2>/dev/null || true)"
  fi
  [[ -z "${rows:-}" ]] && return 0

  rows="$(printf '%s\n' "$rows" | LC_ALL=C sort -t $'\t' -k2,2nr)"

  while IFS=$'\t' read -r fs used; do
    [[ -z "$fs" ]] && continue

    # Größe: erst paddden, dann einfärben -> Spaltentreue trotz ANSI
    local size_hr size_pad size_col size_colored
    size_hr="$(hr "$used")"
    size_pad="$(printf "%8s" "$size_hr")"
    size_col="$(size_color "$used")"
    size_colored="$(c "$size_col" "$size_pad")"

    # Typ: paddden & färben
    local type_pad type_colored
    type_pad="$(printf "%-9s" "filesystem")"
    type_colored="$(c "$COL_FS" "$type_pad")"

    # Name: FS geöffnet hervorheben
    local name_colored
    if [[ -n "$EXPANDED_FS" && "$fs" == "$EXPANDED_FS" ]]; then
      name_colored="$(c "$COL_NAME_FS_OPEN_BOLD" "$fs")"
    else
      name_colored="$(c "$COL_NAME" "$fs")"
    fi

    printf "%s  %s  %s\tFS|%s\n" "$size_colored" "$type_colored" "$name_colored" "$fs"

    # Aufklappen eines Filesystems:
    if [[ -n "$EXPANDED_FS" && "$fs" == "$EXPANDED_FS" ]]; then
      # 1) Volumes der Ebene 1 unterhalb dieses FS
      local vrows
      vrows="$(zfs list -Hp -r -d 1 -t volume -o name,used -- "$fs" 2>/dev/null || true)"
      if [[ -n "$vrows" ]]; then
        vrows="$(printf '%s\n' "$vrows" | LC_ALL=C sort -t $'\t' -k2,2nr)"
        while IFS=$'\t' read -r vname vused; do
          [[ -z "$vname" ]] && continue

          local v_sz_hr v_sz_pad v_sz_col v_sz_colored
          v_sz_hr="$(hr "$vused")"
          v_sz_pad="$(printf "%6s" "$v_sz_hr")"
          v_sz_col="$(size_color "$vused")"
          v_sz_colored="$(c "$v_sz_col" "$v_sz_pad")"

          local arrow="  $(c "$COL_ARROW" "↳")"
          local v_type_pad v_type_colored
          v_type_pad="$(printf "%-9s" "volume")"
          v_type_colored="$(c "$COL_VOL" "$v_type_pad")"
          local v_name_colored
          v_name_colored="$(c "$COL_NAME" "$vname")"

          printf "%s %s  %s  %s\tVOL|%s\n" "$arrow" "$v_sz_colored" "$v_type_colored" "$v_name_colored" "$vname"

          # Falls dieses Volume zusätzlich aufgeklappt ist: Snapshots
          if [[ -n "$EXPANDED_VOL" && "$vname" == "$EXPANDED_VOL" ]]; then
            local snaps snaps_sorted key size
            snaps="$(zfs list -Hp -t snapshot -o name,used,referenced -- "$vname" 2>/dev/null || true)"
            if [[ -n "$snaps" ]]; then
              key=2; [[ "$MODE" == "refer" ]] && key=3
              snaps_sorted="$(printf '%s\n' "$snaps" | LC_ALL=C sort -t $'\t' -k${key},${key}nr)"
              while IFS=$'\t' read -r sname suse sref; do
                [[ -z "$sname" ]] && continue
                if [[ "$MODE" == "used" && "$HIDE_ZERO" -eq 1 && "$suse" -eq 0 ]]; then continue; fi
                size="$suse"; [[ "$MODE" == "refer" ]] && size="$sref"

                local s_sz_hr s_sz_pad s_sz_col s_sz_colored
                s_sz_hr="$(hr "$size")"
                s_sz_pad="$(printf "%4s" "$s_sz_hr")"
                s_sz_col="$(size_color "$size")"
                s_sz_colored="$(c "$s_sz_col" "$s_sz_pad")"

                local s_type_pad s_type_colored
                s_type_pad="$(printf "%-9s" "snapshot")"
                s_type_colored="$(c "$COL_SNAP" "$s_type_pad")"
                local short="${sname/$vname/}"   # 'pool/vol@snap' -> '@snap'
                local short_colored="$(c "$COL_NAME" "$short")"

                printf "    %s  %s  %s\tSNAP|%s\n" "$s_sz_colored" "$s_type_colored" "$short_colored" "$sname"
              done <<< "$snaps_sorted"
            fi
          fi
        done <<< "$vrows"
      fi

      # 2) Snapshots dieses Filesystems
      local snaps_fs snaps_sorted key size
      snaps_fs="$(zfs list -Hp -t snapshot -o name,used,referenced -- "$fs" 2>/dev/null || true)"
      if [[ -n "$snaps_fs" ]]; then
        key=2; [[ "$MODE" == "refer" ]] && key=3
        snaps_sorted="$(printf '%s\n' "$snaps_fs" | LC_ALL=C sort -t $'\t' -k${key},${key}nr)"
        while IFS=$'\t' read -r sname suse sref; do
          [[ -z "$sname" ]] && continue
          if [[ "$MODE" == "used" && "$HIDE_ZERO" -eq 1 && "$suse" -eq 0 ]]; then continue; fi
          size="$suse"; [[ "$MODE" == "refer" ]] && size="$sref"

          local s_sz_hr s_sz_pad s_sz_col s_sz_colored
          s_sz_hr="$(hr "$size")"
          s_sz_pad="$(printf "%6s" "$s_sz_hr")"
          s_sz_col="$(size_color "$size")"
          s_sz_colored="$(c "$s_sz_col" "$s_sz_pad")"

          local s_type_pad s_type_colored
          s_type_pad="$(printf "%-9s" "snapshot")"
          s_type_colored="$(c "$COL_SNAP" "$s_type_pad")"
          local short="${sname/$fs/}"   # 'pool/fs@snap' -> '@snap'
          local short_colored="$(c "$COL_NAME" "$short")"

          printf "  %s  %s  %s\tSNAP|%s\n" "$s_sz_colored" "$s_type_colored" "$short_colored" "$sname"
        done <<< "$snaps_sorted"
      fi
    fi
  done <<< "$rows"
}

confirm_delete() {
  local -a metas=("$@")
  local -a snaps=() volumes=() filesystems=()
  local m

  for m in "${metas[@]}"; do
    case "$m" in
      SNAP\|*) snaps+=("${m#SNAP|}") ;;
      VOL\|*)  volumes+=("${m#VOL|}") ;;
      FS\|*)   filesystems+=("${m#FS|}") ;;
    esac
  done

  local ns=${#snaps[@]} nv=${#volumes[@]} nf=${#filesystems[@]}
  if (( ns==0 && nv==0 && nf==0 )); then
    echo "Nichts ausgewählt zum Löschen."
    read -r -p "Weiter mit Enter..." _
    return 1
  fi

  echo
  echo "⚠️  Löschvorgang vorbereiten:"
  (( ns )) && { echo "  • Snapshots   : $ns"; printf '    - %s\n' "${snaps[@]:0:5}"; [[ $ns -gt 5 ]] && echo "    - ..."; }
  (( nv )) && { echo "  • Volumes     : $nv (rekursiv: inkl. Snapshots)"; printf '    - %s\n' "${volumes[@]:0:5}"; [[ $nv -gt 5 ]] && echo "    - ..."; }
  (( nf )) && { echo "  • Filesystems : $nf (rekursiv!)"; printf '    - %s\n' "${filesystems[@]:0:5}"; [[ $nf -gt 5 ]] && echo "    - ..."; }
  echo
  read -r -p "Wirklich löschen? (ja/NEIN): " ans
  [[ "$ans" == "ja" ]] || { echo "Abgebrochen."; sleep 0.6; return 1; }

  if (( nv + nf )); then
    echo "ACHTUNG: Datasets/Volumes werden mit 'zfs destroy -r' rekursiv entfernt!"
    read -r -p "Zum Fortfahren tippe GENAU: LÖSCHEN : " ans2
    [[ "$ans2" == "LÖSCHEN" ]] || { echo "Abgebrochen."; sleep 0.6; return 1; }
  fi

  # Löschen ausführen (Fehler tolerieren, aber anzeigen)
  local rc=0
  set +e

  # Snapshots pro Dataset gruppieren und kommagetrennt (in Batches) löschen
  if (( ns )); then
    echo
    echo "→ Zerstöre Snapshots..."
    declare -A snap_groups=()
    local s ds sn
    for s in "${snaps[@]}"; do
      ds="${s%@*}"; sn="${s#*@}"
      if [[ -z "${snap_groups[$ds]:-}" ]]; then snap_groups[$ds]="$sn"; else snap_groups[$ds]+=" $sn"; fi
    done

    local ds_key
    for ds_key in "${!snap_groups[@]}"; do
      read -r -a _arr <<< "${snap_groups[$ds_key]}"
      local batch=() count=0 max_batch=128
      for sn in "${_arr[@]}"; do
        batch+=("$sn"); ((count++))
        if (( count >= max_batch )); then (IFS=,; zfs destroy -v -- "$ds_key@${batch[*]}"); rc=$(( rc || $? )); batch=(); count=0; fi
      done
      if (( count > 0 )); then (IFS=,; zfs destroy -v -- "$ds_key@${batch[*]}"); rc=$(( rc || $? )); fi
    done
  fi

  if (( nv )); then
    echo
    echo "→ Zerstöre Volumes rekursiv..."
    local v
    for v in "${volumes[@]}"; do
      zfs destroy -r -v -- "$v"; rc=$(( rc || $? ))
    done
  fi

  if (( nf )); then
    echo
    echo "→ Zerstöre Filesystems rekursiv..."
    local f
    for f in "${filesystems[@]}"; do
      zfs destroy -r -v -- "$f"; rc=$(( rc || $? ))
    done
  fi

  set -e

  if (( rc == 0 )); then
    echo
    echo "✅ Löschen abgeschlossen."
  else
    echo
    echo "⚠️  Einige Löschoperationen sind fehlgeschlagen. Details siehe oben."
  fi
  echo
  read -r -p "Weiter mit Enter..." _
  return 0
}

run_ui() {
  while :; do
    # Dynamischer Header
    hdr="Enter/→: öffnen   Backspace/←: zurück   ␣: markieren   d: löschen   r: used↔refer (jetzt: $MODE)   z: 0B "
    if [[ "$MODE" == "used" && "$HIDE_ZERO" -eq 1 ]]; then hdr+="ausgeblendet"; else hdr+="sichtbar"; fi
    hdr+="   q/ESC: raus"

    # fzf Farb-Option
    local color_opt=()
    if (( COLOR )); then color_opt+=( --color="$FZF_COLORS" ); fi

    sel="$(
      build_list \
      | fzf --ansi --with-nth=1 --delimiter=$'\t' \
            --prompt="zfsdu> " \
            --border --height=100% --margin=0 --reverse \
            --multi --marker='* ' --bind "space:toggle" \
            --expect=enter,esc,left,right,bspace,r,d,z \
            --bind "q:abort,ctrl-c:abort" \
            --header="$hdr" \
            --preview='
              meta=$(echo {} | cut -f2)
              kind=${meta%%|*}; name=${meta#*|}
              # Farbige Preview: Property cyan, Wert normal
              pr() { awk -F"\t" '"'"'
                function hr(n,u,i){split("B KiB MiB GiB TiB PiB EiB ZiB YiB",u," ");
                                    i=1; while(n>=1024 && i<length(u)){n/=1024;i++}
                                    return sprintf("%.1f %s", n, u[i]);}
                function c(code, s){return sprintf("\033[%sm%s\033[0m", code, s);}
                {
                  v=$2;
                  if (v ~ /^[0-9]+$/) vv=hr(v); else vv=v;
                  printf "%-14s: %-12s %s\n", c(36,$1), vv, $3
                }'"'"'; }
              if [ "$kind" = "FS" ]; then
                zfs get -H -p -o property,value,source used,referenced,available,mountpoint "$name" 2>/dev/null | pr
              elif [ "$kind" = "VOL" ]; then
                zfs get -H -p -o property,value,source type,used,referenced,available,volsize,volblocksize "$name" 2>/dev/null | pr
              else
                zfs get -H -p -o property,value,source referenced,used,creation "$name" 2>/dev/null | pr
              fi
            ' \
            --preview-window=right,60% \
            "${color_opt[@]}"
    )" || break

    key="$(printf '%s\n' "$sel" | head -n1)"
    mapfile -t lines < <(printf '%s\n' "$sel" | sed '1d')
    if (( ${#lines[@]} == 0 )); then
      line="$(printf '%s\n' "$sel" | sed -n '2p')"
      [[ -n "$line" ]] && lines=("$line")
    fi

    # r: Modus wechseln (wirkt auf Snapshots used↔referenced)
    if [[ "$key" == "r" ]]; then
      if [[ "$MODE" == "used" ]]; then MODE="refer"; else MODE="used"; fi
      continue
    fi

    # z: 0B-Snapshots zeigen/ausblenden (wirkt nur im MODE=used auf die Filterung)
    if [[ "$key" == "z" ]]; then
      if [[ "$HIDE_ZERO" -eq 1 ]]; then HIDE_ZERO=0; else HIDE_ZERO=1; fi
      continue
    fi

    # d: Markierte Einträge löschen
    if [[ "$key" == "d" ]]; then
      mapfile -t metas < <(printf '%s\n' "${lines[@]}" | awk -F'\t' '{print $2}' | sed '/^$/d')
      confirm_delete "${metas[@]}"
      continue
    fi

    # Metadaten der aktuellen Zeile
    line_first="${lines[0]-}"
    [[ -z "$line_first" ]] && continue
    meta="$(printf '%s\n' "$line_first" | awk -F'\t' '{print $2}')"
    kind="${meta%%|*}"
    name="${meta#*|}"

    case "$key" in
      enter|right)
        case "$kind" in
          FS)
            if [[ "$EXPANDED_FS" == "$name" ]]; then
              EXPANDED_FS=""; EXPANDED_VOL=""
            else
              EXPANDED_FS="$name"; EXPANDED_VOL=""
            fi
            ;;
          VOL)
            p="$(parent_ds "$name")"
            if [[ "$EXPANDED_VOL" == "$name" ]]; then
              EXPANDED_VOL=""
            else
              EXPANDED_VOL="$name"
              [[ "$EXPANDED_FS" != "$p" ]] && EXPANDED_FS="$p"
            fi
            ;;
        esac
        ;;
      bspace|left)
        if [[ -n "$EXPANDED_VOL" ]]; then
          EXPANDED_VOL=""
        elif [[ -n "$EXPANDED_FS" ]]; then
          EXPANDED_FS=""
        else
          break
        fi
        ;;
      esc) break ;;
    esac
  done
}

run_ui
