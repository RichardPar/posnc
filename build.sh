#!/bin/sh
# build.sh -- build NC.TSK for P/OS using Pascal-2 on the RSX-11M-PLUS host.
#
# Uploads the sources to DB0:[NCPOS] over the RSX terminal line (rsxd.py must
# be running and logged in), runs @NCMAKE there, and fetches the task image
# back as ./NC.TSK.  Deploy it to the Pro with ../posdeploy.sh.
set -e
cd "$(dirname "$0")"
T=..
DIR='DB0:[NCPOS]'

python3 $T/rsx.py "SET /DEF=$DIR" >/dev/null
for f in nc.pas ncio.mac ncbld.cmd ncmake.cmd; do
  python3 $T/rsxput.py "$f" "$DIR$(echo $f | tr a-z A-Z)"
done

echo "== building on RSX"
out=$(python3 $T/rsx.py -t 60 "SET /DEF=$DIR" "@NCMAKE")
msgs=$(echo "$out" | grep -v '^\s*$' | grep -vE '^(>|SET /DEF|@NCMAKE)' || true)
echo "$msgs"
if echo "$msgs" | grep -qiE 'error|illegal|undefined|fatal|--'; then
  echo "== build failed"; exit 1
fi

python3 $T/rsx.py -t 10 "TYPE ${DIR}NC.MAP" | grep -E 'image  size' || true
python3 $T/rsxget.py "${DIR}NC.TSK" NC.TSK
python3 $T/rsx.py "PURGE ${DIR}*.*/KE:2" >/dev/null 2>&1 || true
ls -l NC.TSK
