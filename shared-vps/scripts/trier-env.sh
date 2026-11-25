#!/usr/bin/env bash
# Range le .env de la VPS dans l'ordre et les sections de .env.example (par application),
# SANS rien perdre et SANS jamais afficher une valeur.
#
#   cd ~/hizope-scaleway-deploy/shared-vps
#   ./scripts/trier-env.sh            # écrit .env.trie, ne touche pas à .env
#   diff <(grep -oE '^[A-Z0-9_]+' .env | sort) <(grep -oE '^[A-Z0-9_]+' .env.trie | sort)   # mêmes variables ?
#   cp .env .env.bak-$(date +%F) && mv .env.trie .env && chmod 600 .env
#   docker compose -f docker-compose.prod.yml up -d   # relit le .env (rien ne change si les valeurs sont les mêmes)
#
# Ce que fait le tri :
# - chaque variable de ton .env est recopiée telle quelle (ligne entière, valeur intacte)
#   à sa place dans les sections de .env.example ;
# - une variable de l'exemple absente de ton .env apparaît en commentaire « # ABSENTE » ;
# - une variable de ton .env inconnue de l'exemple (ancienne ?) est gardée, à la fin, dans
#   une section « À VÉRIFIER » ;
# - si une variable est définie deux fois, la DERNIÈRE est gardée (c'est celle que docker
#   compose utilisait déjà) ;
# - tes propres commentaires sont remplacés par ceux de l'exemple (ils restent dans la
#   sauvegarde .env.bak-...).
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Pas de .env dans $(pwd)"; exit 1; }
[ -f .env.example ] || { echo "Pas de .env.example dans $(pwd)"; exit 1; }

python3 - <<'PY'
import re

VAR = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=")

def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read().splitlines()

env_lines = read(".env")
example_lines = read(".env.example")

# Variables de TON .env : dernière définition gagnante (comme docker compose).
values, counts = {}, {}
for line in env_lines:
    m = VAR.match(line)
    if m:
        name = m.group(1)
        values[name] = line.strip()
        counts[name] = counts.get(name, 0) + 1

out, used, missing = [], set(), []
for line in example_lines:
    m = VAR.match(line)
    if not m:
        out.append(line)  # commentaires et lignes vides de l'exemple
        continue
    name = m.group(1)
    if name in values:
        out.append(values[name])
        used.add(name)
    else:
        out.append(f"# ABSENTE de ton .env : {name}=")
        missing.append(name)

unknown = [n for n in values if n not in used]
if unknown:
    out += ["", "#" * 88,
            "#   À VÉRIFIER : variables de ton .env inconnues de .env.example",
            "#   (plus utilisées ? faute de frappe ? à ajouter dans .env.example ?)",
            "#" * 88]
    out += [values[n] for n in unknown]

with open(".env.trie", "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")

print(f".env.trie écrit : {len(used)} variables rangées, aucune valeur affichée.")
if missing:
    print(f"\nAbsentes de ton .env ({len(missing)}) — normal si l'appli n'en a pas besoin :")
    for n in missing:
        print(f"  - {n}")
if unknown:
    print(f"\nInconnues de .env.example, gardées à la fin ({len(unknown)}) :")
    for n in unknown:
        print(f"  - {n}")
dups = [n for n, c in counts.items() if c > 1]
if dups:
    print(f"\nDéfinies plusieurs fois, la dernière est gardée ({len(dups)}) :")
    for n in dups:
        print(f"  - {n}")
PY

chmod 600 .env.trie
echo
echo "Relis .env.trie, puis : cp .env .env.bak-\$(date +%F) && mv .env.trie .env && chmod 600 .env"
