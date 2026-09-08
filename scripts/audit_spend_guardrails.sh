#!/usr/bin/env bash
#
# Read-only audit of every control that can stop this project spending money.
#
# Written because the guardrails were built piecemeal over several days and
# "I set that" is not evidence. Everything here is queried live; nothing is
# taken on trust from a previous session.
set -uo pipefail

GC="${GCLOUD:-$HOME/google-cloud-sdk/bin/gcloud}"
PROJECT="ant-assistive-nav"
GEMINI_PROJECT="gen-lang-client-0943644282"
BILLING="billingAccounts/012836-330A82-6E5706"
SA="514133180208-compute@developer.gserviceaccount.com"

row() { printf "  %-46s %s\n" "$1" "$2"; }

q() { # service metric unit -> effective limit
  "$GC" alpha services quota list --service="$1" --consumer="projects/$PROJECT" \
    --format="json" 2>/dev/null \
  | python3 -c "
import json,sys
metric,unit=sys.argv[1],sys.argv[2]
try: d=json.load(sys.stdin)
except Exception: print('QUERY FAILED'); raise SystemExit
for m in d:
    for l in m.get('consumerQuotaLimits',[]):
        if l.get('metric')==metric and l.get('unit')==unit:
            for b in l.get('quotaBuckets',[]):
                print(b.get('effectiveLimit','?')); raise SystemExit
print('NOT SET')
" "$1_$2" "$3" 2>/dev/null || echo "ERROR"
}

qq() { # service metric unit -> limit, via a simpler path
  "$GC" alpha services quota list --service="$1" --consumer="projects/$PROJECT" \
    --format="json" 2>/dev/null | python3 -c "
import json,sys
metric,unit=sys.argv[1],sys.argv[2]
d=json.load(sys.stdin)
for m in d:
    for l in m.get('consumerQuotaLimits',[]):
        if l.get('metric')==metric and l.get('unit')==unit:
            for b in l.get('quotaBuckets',[]):
                print(b.get('effectiveLimit','?')); raise SystemExit
print('NOT SET')
" "$2" "$3"
}

echo "=============================================="
echo " 1. Google-enforced quotas (hard, real-time)"
echo "=============================================="
row "geocoding billable_default /day" "$(qq geocoding-backend.googleapis.com geocoding-backend.googleapis.com/billable_default '1/d/{project}')"
row "geocoding billable_default /min" "$(qq geocoding-backend.googleapis.com geocoding-backend.googleapis.com/billable_default '1/min/{project}')"
row "routes compute_routes /day" "$(qq routes.googleapis.com routes.googleapis.com/compute_routes_requests '1/d/{project}')"
row "routes compute_routes /min" "$(qq routes.googleapis.com routes.googleapis.com/compute_routes_requests '1/min/{project}')"
row "places SearchText /day" "$(qq places.googleapis.com places.googleapis.com/SearchTextRequest '1/d/{project}')"
row "places SearchNearby /day" "$(qq places.googleapis.com places.googleapis.com/SearchNearbyRequest '1/d/{project}')"
row "speech audioseconds /day" "$(qq speech.googleapis.com speech.googleapis.com/audioseconds_requests '1/d/{project}')"
row "speech default_requests /min" "$(qq speech.googleapis.com speech.googleapis.com/default_requests '1/min/{project}')"
row "tts requests /min" "$(qq texttospeech.googleapis.com texttospeech.googleapis.com/requests '1/min/{project}')"
row "tts requests_neural2 /min" "$(qq texttospeech.googleapis.com texttospeech.googleapis.com/requests_neural2 '1/min/{project}')"
row "tts requests_studio /min  (unused, \$160/1M)" "$(qq texttospeech.googleapis.com texttospeech.googleapis.com/requests_studio '1/min/{project}')"

echo
echo "=============================================="
echo " 2. API key restrictions"
echo "=============================================="
for uid in $("$GC" services api-keys list --project="$PROJECT" --format="value(uid)" 2>/dev/null); do
  "$GC" services api-keys describe "$uid" --project="$PROJECT" --format="json" 2>/dev/null | python3 -c "
import json,sys
k=json.load(sys.stdin)
r=k.get('restrictions',{})
app='android' if r.get('androidKeyRestrictions') else ('browser' if r.get('browserKeyRestrictions') else ('server' if r.get('serverKeyRestrictions') else 'NONE'))
apis=r.get('apiTargets')
print('  %-40s app-restriction=%-8s apis=%s' % (k.get('displayName','?')[:40], app, len(apis) if apis else 'UNRESTRICTED'))
"
done

echo
echo "=============================================="
echo " 3. Budget + kill switch"
echo "=============================================="
TOKEN=$("$GC" auth print-access-token 2>/dev/null)
curl -s "https://billingbudgets.googleapis.com/v1/$BILLING/budgets" \
  -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT" \
| python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d: print('  budget query failed:', d['error']['message'][:80]); raise SystemExit
for b in d.get('budgets',[]):
    a=b.get('amount',{}).get('specifiedAmount',{})
    t=b.get('notificationsRule',{}).get('pubsubTopic','NONE')
    print('  %-46s %s %s' % ('budget \"%s\"' % b['displayName'][:28], a.get('units'), a.get('currencyCode')))
    print('  %-46s %s' % ('  -> pubsub topic', t.split('/')[-1] if t!='NONE' else 'NOT CONNECTED'))
    print('  %-46s %s' % ('  -> thresholds', [int(r.get('thresholdPercent',0)*100) for r in b.get('thresholdRules',[])]))
"
FN=$("$GC" functions describe disableBillingOnBudgetExceeded --project="$PROJECT" --region=us-east1 --format="value(state,updateTime)" 2>/dev/null)
row "kill-switch function" "${FN:-NOT DEPLOYED}"
ROLE=$("$GC" projects get-iam-policy "$PROJECT" --flatten="bindings[].members" \
  --filter="bindings.members:$SA AND bindings.role:serviceusage" --format="value(bindings.role)" 2>/dev/null)
row "runtime SA can disable services" "${ROLE:-MISSING ROLE}"

echo
echo "=============================================="
echo " 4. Client-side ceiling (ApiBudget)"
echo "=============================================="
CUR=$(date -u +%Y-%m)
"$GC" firestore databases list --project="$PROJECT" --format="value(name)" >/dev/null 2>&1 \
  && row "firestore reachable" "yes" || row "firestore reachable" "NO"
grep -q "api_usage" firestore.rules 2>/dev/null && row "api_usage rule present in repo" "yes" || row "api_usage rule present in repo" "NO"
grep -oE "BillableApi\.[a-z]+: [0-9]+" ant_app/lib/core/services/api_budget.dart 2>/dev/null | sed 's/^/    /'

echo
echo "=============================================="
echo " 5. Gemini (separate project)"
echo "=============================================="
GB=$("$GC" billing projects describe "$GEMINI_PROJECT" --format="value(billingEnabled)" 2>/dev/null)
row "$GEMINI_PROJECT billing enabled" "${GB:-unknown}"
row "  -> can it be charged?" "$([ "$GB" = "False" ] && echo 'no - free tier only, 429 instead of a bill' || echo 'YES - needs its own budget')"

echo
echo "=============================================="
echo " 6. Billable services with NO quota guardrail"
echo "=============================================="
echo "  These bill on Blaze and are NOT disabled by the kill switch,"
echo "  because the app cannot function without them:"
row "firestore.googleapis.com" "free tier, then per-read/write"
row "cloudfunctions.googleapis.com" "free tier, then per-invocation"
row "storage.googleapis.com" "free tier, then per-GB"
echo "  Guardrail for these is the \$2 budget alert only (notification)."
