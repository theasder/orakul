#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ARCH="${MEETGPT_ARCH:-native}"
SWIFT_BUILD_ARGS=(-c release)
case "$BUILD_ARCH" in
    native)
        DEFAULT_APP_BASENAME="orakul"
        ;;
    arm64|x86_64)
        SWIFT_BUILD_ARGS+=(--triple "${BUILD_ARCH}-apple-macosx13.0"
                           --scratch-path "$ROOT/.build/$BUILD_ARCH")
        if [ "$BUILD_ARCH" = "x86_64" ]; then
            DEFAULT_APP_BASENAME="orakul-Intel"
        else
            DEFAULT_APP_BASENAME="orakul"
        fi
        ;;
    *)
        echo "!! unsupported MEETGPT_ARCH=$BUILD_ARCH (use native, arm64, or x86_64)" >&2
        exit 2
        ;;
esac
APP_BASENAME="${MEETGPT_APP_BASENAME:-$DEFAULT_APP_BASENAME}"
STAGE="$ROOT/build/$APP_BASENAME.app"    # staging copy inside the repo
ENT="$ROOT/Support/MeetGPT.entitlements"
SANDBOX_ENT="$ROOT/Support/MeetGPT.sandbox.entitlements"
# App Sandbox is MANDATORY for distribution (the Mac App Store requires it), and
# opt-in for a dev build via MEETGPT_SANDBOX=1. A dist build (MEETGPT_DIST=1, set
# by notarize.sh / appstore.sh) ALWAYS signs with the sandboxed entitlements —
# the non-sandbox profile can never ship (M8). Screen/audio capture + the
# loopback OAuth listener still need an interactive check under the sandbox
# (M8 runtime gate — a dev build never exercises them sandboxed).
if [ "${MEETGPT_DIST:-0}" = "1" ] || [ "${MEETGPT_SANDBOX:-0}" = "1" ]; then
    # Fail-safe: a distribution build must never silently fall back to the
    # non-sandbox profile if the entitlements file is missing.
    if [ ! -f "$SANDBOX_ENT" ]; then
        echo "!! sandbox entitlements missing ($SANDBOX_ENT) — refusing to build" >&2
        exit 1
    fi
    ENT="$SANDBOX_ENT"
    if [ "${MEETGPT_DIST:-0}" = "1" ]; then
        echo ">> SANDBOXED build (mandatory for distribution)"
    else
        echo ">> SANDBOXED build (opt-in) — verify system-audio/mic capture + OAuth loopback before relying on it"
    fi
fi
# Inspection hatch: print the resolved entitlements and exit (no compile/sign).
# Lets CI/humans confirm the dist→sandbox tie without a full build.
if [ "${MEETGPT_PRINT_ENT:-0}" = "1" ]; then
    echo "ENT=$ENT"
    exit 0
fi
ICON="$ROOT/Support/AppIcon.icns"

# Install to a STABLE location so the app always runs from the same path.
# macOS TCC (Screen Recording / Microphone) is happier when the bundle path
# doesn't move between launches. Override with MEETGPT_APP_DIR, or set
# MEETGPT_NO_INSTALL=1 to run straight from the repo staging copy.
APP_DIR="${MEETGPT_APP_DIR:-/Applications}"
DEST="$APP_DIR/$APP_BASENAME.app"
LEGACY_DEST="$APP_DIR/MeetGPT.app"

cd "$ROOT"

# --- Generate Secrets.swift from .env (build-time key injection) ---
# Keys leave the UI and live in mac/.env; we bake them into a gitignored
# Secrets.swift so they compile into the app. No .env → empty keys (still builds).
echo ">> generating Secrets.swift from .env"
ENV_FILE="$ROOT/.env"
SECRETS="$ROOT/Sources/MeetGPT/Secrets.swift"

# Distribution hardening: a release build (MEETGPT_DIST=1, set by notarize.sh)
# bakes NO provider/org secrets into the binary. The shipped app serves LLM
# through the backend gateway (LLM_GATEWAY=backend — keys stay server-side) and
# transcribes on-device (TRANSCRIPTION_ENGINE=local). Dev builds (flag unset)
# keep keys baked for local iteration.
DIST="${MEETGPT_DIST:-0}"
SECRET_VARS="OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_AI_API_KEY DEEPGRAM_API_KEY ASSEMBLYAI_API_KEY DEEPSEEK_API_KEY DASHSCOPE_API_KEY ZHIPU_API_KEY MOONSHOT_API_KEY HUBSPOT_CLIENT_ID HUBSPOT_CLIENT_SECRET AFFINITY_CLIENT_ID AFFINITY_CLIENT_SECRET ZOOM_CLIENT_ID ZOOM_CLIENT_SECRET SLACK_BOT_TOKEN SLACK_CHANNEL_IDS CONFLUENCE_SITE CONFLUENCE_EMAIL CONFLUENCE_TOKEN"

sw() {  # sw VAR  -> value of VAR from .env (empty if absent), Swift-string-escaped
    if [ "$DIST" = "1" ]; then
        # Never emit a provider/org secret into a distributed binary.
        case " $SECRET_VARS " in *" $1 "*) printf ''; return ;; esac
        # orakul: прямой доступ к провайдеру, не через шлюз.
        #
        # У Cruxwing здесь стояло 'backend' — и это правильно для продукта, у
        # которого сервер есть: ключи остаются на сервере, в бинарник не
        # попадает ничего. У orakul сервера нет (api.orakul.ai не резолвится),
        # поэтому то же значение означало бы: каждый запрос уходит в никуда,
        # введённый пользователем ключ не читается вовсе, а isConfigured
        # отвечает «настроено» за все провайдеры сразу. Установщик выглядел бы
        # рабочим и не отвечал ни на один вопрос — так и было, пока не поймали.
        #
        # Гарантия «в бинарнике нет секретов» не меняется: SECRET_VARS выше
        # по-прежнему стирает все ключи. Ключ приезжает из Связки ключей в
        # рантайме, его вводит человек в настройках.
        [ "$1" = "LLM_GATEWAY" ] && { printf 'direct'; return; }
        # Расшифровка — на устройстве. 'server' означал бы managed Whisper на
        # нашем сервере, которого нет.
        [ "$1" = "TRANSCRIPTION_ENGINE" ] && { printf 'local'; return; }
        # Адрес сервера не бакается: у orakul сервера нет.
        #
        # У cruxwing здесь подставлялся боевой адрес, потому что без него
        # первый запуск упирался в пустоту. У orakul наоборот. LLM_GATEWAY
        # выше уже переключён на 'direct': запрос идёт к провайдеру с ключом
        # пользователя, и адрес в бинарнике не нужен ни для чего. Любой,
        # который сюда попадёт, будет либо мёртвым (`http://localhost:8787` —
        # из рабочей копии сборщика), либо чужим (`https://api.cruxwing.ai` —
        # сервер другого продукта). Второе хуже: этот адрес существует и
        # отвечает.
        #
        # Пустая строка — рабочее значение, а не заглушка: Config и AppState
        # проверяют её через `.isEmpty` и в этом случае не показывают вход и
        # серверные модели.
        [ "$1" = "BACKEND_URL" ] && { printf ''; return; }
    fi
    local v=""
    if [ -f "$ENV_FILE" ]; then
        v="$(grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
    fi
    # This repo's own .env is the ONLY source. There used to be a fallback to a
    # repo-root .env one level up, which in the monorepo resolved to the
    # backend's env and let the Mac build inherit provider keys it had not been
    # given. The split made these repos independent, so that path now resolves
    # to whatever directory the checkouts happen to share — nothing, a sibling
    # project, or somebody else's secrets.
    #
    # Losing it costs nothing here: the app ships with LLM_GATEWAY=backend, so
    # provider keys stay server-side by design and every *_API_KEY in mac/.env is
    # deliberately empty. A dev build that genuinely wants direct provider access
    # sets the key in this repo's .env, explicitly.
    # strip an inline comment (# at line start or after whitespace) + trim, so a
    # value like `BACKEND_URL= # fill me` bakes as empty, not the comment text.
    v="$(printf '%s' "$v" | sed -E 's/(^|[[:space:]])#.*$/\1/; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    v="${v%\"}"; v="${v#\"}"                 # strip optional surrounding quotes
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"      # escape backslash and quote
    printf '%s' "$v"
}
cat > "$SECRETS" <<EOF
// GENERATED FILE — do not edit or commit real values.
// build.sh regenerates this from mac/.env on every build. It is gitignored.
enum Secrets {
    static let openAIAPIKey    = "$(sw OPENAI_API_KEY)"
    static let anthropicAPIKey = "$(sw ANTHROPIC_API_KEY)"
    static let googleAIAPIKey  = "$(sw GOOGLE_AI_API_KEY)"
    static let deepgramAPIKey  = "$(sw DEEPGRAM_API_KEY)"
    static let assemblyAIAPIKey = "$(sw ASSEMBLYAI_API_KEY)"
    static let googleClientID  = "$(sw GOOGLE_CLIENT_ID)"
    // A native OAuth client cannot keep this credential confidential, so Google
    // does not treat it as a server secret. Keep it in distribution builds too;
    // it identifies the Desktop client during code exchange and token refresh.
    static let googleClientSecret = "$(sw GOOGLE_CLIENT_SECRET)"
    static let backendBaseURL  = "$(sw BACKEND_URL)"
    static let backendCertPins = "$(sw BACKEND_CERT_PINS)"
    static let transcriptionEngine = "$(sw TRANSCRIPTION_ENGINE)"
    static let transcriptionChunkSeconds = "$(sw TRANSCRIPTION_CHUNK_SECONDS)"
    static let transcriptionChunkOverlapSeconds = "$(sw TRANSCRIPTION_CHUNK_OVERLAP_SECONDS)"
    static let transcriptionBoundarySlackSeconds = "$(sw TRANSCRIPTION_BOUNDARY_SLACK_SECONDS)"
    static let defaultTier     = "$(sw DEFAULT_TIER)"
    // NOT read from .env: "1" only when this is a dev build (MEETGPT_DIST unset).
    // Gates the in-app Developer tools (tier preview). Dist builds bake "0".
    static let devMode         = "$([ "$DIST" = "1" ] && printf '0' || printf '1')"
    static let localWhisperModel = "$(sw TRANSCRIPTION_LOCAL_MODEL)"
    static let transcriptionVAD = "$(sw TRANSCRIPTION_VAD)"
    static let transcriptionLanguage = "$(sw TRANSCRIPTION_LANGUAGE)"
    static let llmGateway      = "$(sw LLM_GATEWAY)"
    static let deepSeekAPIKey  = "$(sw DEEPSEEK_API_KEY)"
    static let dashScopeAPIKey = "$(sw DASHSCOPE_API_KEY)"
    static let zhipuAPIKey     = "$(sw ZHIPU_API_KEY)"
    static let moonshotAPIKey  = "$(sw MOONSHOT_API_KEY)"
    static let ensemblePanel   = "$(sw ENSEMBLE_PANEL)"
    static let ensembleChairman = "$(sw ENSEMBLE_CHAIRMAN)"
    static let hubSpotClientID = "$(sw HUBSPOT_CLIENT_ID)"
    static let hubSpotClientSecret = "$(sw HUBSPOT_CLIENT_SECRET)"
    static let affinityClientID = "$(sw AFFINITY_CLIENT_ID)"
    static let affinityClientSecret = "$(sw AFFINITY_CLIENT_SECRET)"
    static let zoomClientID = "$(sw ZOOM_CLIENT_ID)"
    static let zoomClientSecret = "$(sw ZOOM_CLIENT_SECRET)"
    static let googleSignInClientID = "$(sw GOOGLE_SIGNIN_CLIENT_ID)"
    static let googleSignInClientSecret = "$(sw GOOGLE_SIGNIN_CLIENT_SECRET)"
    static let gmailClientID = "$(sw GMAIL_CLIENT_ID)"
    static let gmailClientSecret = "$(sw GMAIL_CLIENT_SECRET)"
    static let googleAnalyticsClientID = "$(sw GOOGLE_ANALYTICS_CLIENT_ID)"
    static let googleAnalyticsClientSecret = "$(sw GOOGLE_ANALYTICS_CLIENT_SECRET)"
    static let slackBotToken   = "$(sw SLACK_BOT_TOKEN)"
    static let slackChannelIDs = "$(sw SLACK_CHANNEL_IDS)"
    static let confluenceSite  = "$(sw CONFLUENCE_SITE)"
    static let confluenceEmail = "$(sw CONFLUENCE_EMAIL)"
    static let confluenceToken = "$(sw CONFLUENCE_TOKEN)"
    static let teamWatchAutoAck = "$(sw TEAM_WATCH_AUTO_ACK)"
}
EOF

if [ "$DIST" = "1" ]; then
    echo ">> DIST build: ключи не бакаются — их вводит человек, расшифровка на устройстве"
    DIST_BACKEND="$(sw BACKEND_URL)"
    # Проверка перевёрнута против cruxwing. Там запрещался адрес рабочей копии
    # (`localhost`) при обязательном боевом; здесь запрещён любой непустой:
    # orakul ходит к провайдеру напрямую, сервера у него нет, и адрес в
    # бинарнике может только увести данные не туда. Останов жёсткий, потому что
    # на машине сборщика такая ошибка не видна.
    if [ -n "$DIST_BACKEND" ]; then
        echo "!! В DIST-сборку попал адрес сервера ($DIST_BACKEND) — отказ." >&2
        echo "!! У orakul нет сервера: LLM_GATEWAY=direct, ключ пользователя, запрос к провайдеру." >&2
        echo "!! Убрать подстановку BACKEND_URL в sw() выше, а не задавать переменную." >&2
        exit 1
    fi
    echo ">> сервер не задан — так и задумано"
fi

echo ">> swift build (release, $BUILD_ARCH)"
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/MeetGPT"
[ -x "$BIN" ] || { echo "!! built executable missing: $BIN" >&2; exit 1; }

echo ">> packaging $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BIN" "$STAGE/Contents/MacOS/MeetGPT"
cp "$ROOT/Support/Info.plist" "$STAGE/Contents/Info.plist"
# MAS requires a strictly increasing CFBundleVersion — derive from git height.
BUILD_NUM="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$STAGE/Contents/Info.plist" 2>/dev/null || true
# The commit this bundle was actually built from, so a shipped artifact can be
# traced back to source without guessing. A release chain that checks out the
# wrong ref still produces a green log and a working DMG — the only way to
# catch it is to ask the binary what it is, which needs this stamp to exist.
GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Add :OrakulCommit string $GIT_SHA" "$STAGE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :OrakulCommit $GIT_SHA" "$STAGE/Contents/Info.plist" 2>/dev/null || true
# Хеш самих исходников — потому что коммита мало.
#
# Коммит отвечает на вопрос «какой ref был выписан», а не «что внутри». При
# незакоммиченном дереве он врёт молча: 12 августа подряд собрано девять разных
# DMG, и все девять несли один и тот же `OrakulCommit`, при 149 изменённых
# файлах. Отличить сборку с десятью коннекторами от вчерашней по штампу было
# нельзя.
#
# `Secrets.swift` исключён: он генерируется при каждой сборке из .env, и его
# содержимое зависит от режима, а не от исходников. Включив его, мы получили бы
# разный хеш у dev- и dist-сборки одного и того же кода.
# Ядро входит в хеш наравне с приложением. Раньше считалось только по
# `Sources/MeetGPT`, а с тех пор приложение линкует OrakulCore: коннекторы,
# словарь и поиск ушли туда и физически лежат в этом же бинарнике. Проверено:
# три файла ядра поменялись, бинарник пересобрался — штамп остался прежним.
# Штамп, который не замечает половину того, что отгружает, хуже отсутствующего:
# на него ссылается форма отчёта об ошибке.
SOURCE_HASH="$(cd "$ROOT/.." && find app/Sources/MeetGPT mvp/Sources/OrakulCore -type f \
    ! -name Secrets.swift | LC_ALL=C sort | xargs shasum -a 1 2>/dev/null \
    | shasum -a 1 | cut -c1-12)"
/usr/libexec/PlistBuddy -c "Add :OrakulSourceHash string $SOURCE_HASH" "$STAGE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :OrakulSourceHash $SOURCE_HASH" "$STAGE/Contents/Info.plist" 2>/dev/null || true
echo ">> исходники: $SOURCE_HASH (коммит $GIT_SHA)"
# App-level privacy manifest (App Review requirement).
cp "$ROOT/Support/PrivacyInfo.xcprivacy" "$STAGE/Contents/Resources/PrivacyInfo.xcprivacy"

# SwiftPM emits bundled resources (the vendored Agent Skills + role matrix) as
# a sibling resource bundle next to the built binary. In the .app it belongs in
# Contents/Resources: that's where Bundle.module's packaged-app search looks
# (Bundle.main.resourceURL), and codesign rejects loose bundles inside
# Contents/MacOS ("bundle format unrecognized").
RES_BUNDLE="$(dirname "$BIN")/MeetGPT_MeetGPT.bundle"
if [ -d "$RES_BUNDLE" ]; then
    rm -rf "$STAGE/Contents/Resources/MeetGPT_MeetGPT.bundle"
    cp -R "$RES_BUNDLE" "$STAGE/Contents/Resources/"
else
    echo ">> warning: $RES_BUNDLE missing — bundled skills won't be available"
fi
if [ -f "$ICON" ]; then
    cp "$ICON" "$STAGE/Contents/Resources/AppIcon.icns"
else
    echo ">> warning: $ICON missing — app will use the generic icon"
fi

# Pick a stable signing identity if one exists — otherwise ad-hoc.
# Stable signatures let macOS remember Screen Recording / Microphone grants
# across rebuilds. Ad-hoc re-signs every build, so macOS sees "a new app"
# every time and drops TCC permissions.
SIGN_ID="${MEETGPT_SIGN_ID:-}"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(printf '%s\n' "$IDENTITIES" \
              | grep -m1 "Developer ID Application" \
              | awk -F'"' '{print $2}' || true)"
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(printf '%s\n' "$IDENTITIES" \
              | grep -Em1 'Apple Development|Mac Developer|MeetGPT' \
              | awk -F'"' '{print $2}' || true)"
fi
if [ -z "$SIGN_ID" ]; then
    # Self-signed dev certs are not "valid" (-v) until trusted in the keychain,
    # but codesign can still sign with them — and TCC keys on their stable
    # identity, which is all we need. Pick up an untrusted MeetGPT cert too.
    SIGN_ID="$(security find-identity -p codesigning 2>/dev/null \
              | grep -Em1 'MeetGPT' | awk -F'"' '{print $2}' || true)"
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="-"
    echo ">> codesign: no stable identity found, using ad-hoc ( - )"
    echo "   Screen Recording / Microphone grants will reset on every rebuild."
    echo "   Fix once:  ./create-signing-cert.sh   (then rebuild)"
else
    echo ">> codesign: using identity \"$SIGN_ID\""
fi

# Sign in with Apple is a RESTRICTED entitlement, and TWO things must line up
# before a binary may carry it:
#   1. an Apple-issued signing identity, and
#   2. an embedded provisioning profile whose App ID grants the capability.
# An Apple identity ALONE is not enough — this gate used to assume it was, and
# the resulting build was pathological to diagnose: it installed, `codesign
# --verify --deep --strict` reported "valid on disk / satisfies its Designated
# Requirement", spctl objected only to notarization, and then launchd refused to
# spawn it with "Launch failed", POSIX 153, no crash report and nothing in the
# system log. The user just sees "The application Cruxwing can't be opened."
# So drop the entitlement whenever either half is missing. Sign in with Apple is
# then absent from that build; Google and email OTP sign-in still work.
PROFILE="${MEETGPT_PROVISION_PROFILE:-$ROOT/Support/embedded.provisionprofile}"
SIGN_ENT="$ENT"
KEEP_APPLESIGNIN=0
case "$SIGN_ID" in
    "Developer ID Application"*|"Apple Development"*|"Apple Distribution"*|"3rd Party Mac Developer"*)
        [ -f "$PROFILE" ] && KEEP_APPLESIGNIN=1
        ;;
esac

if [ "$KEEP_APPLESIGNIN" = "1" ]; then
    # codesign seals the profile from inside the bundle, so it has to be in
    # place before signing, not after.
    cp "$PROFILE" "$STAGE/Contents/embedded.provisionprofile"
    echo ">> Sign in with Apple: enabled via $PROFILE"
else
    rm -f "$STAGE/Contents/embedded.provisionprofile"
    SIGN_ENT="$ROOT/build/.local.entitlements"
    mkdir -p "$ROOT/build"
    cp "$ENT" "$SIGN_ENT"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.applesignin' "$SIGN_ENT" >/dev/null 2>&1 || true
    if [ -f "$PROFILE" ]; then
        WHY="signing identity \"$SIGN_ID\" is not Apple-issued"
    else
        WHY="no provisioning profile at $PROFILE"
    fi
    # В cruxwing здесь был жёсткий останов: сборка без этого entitlement теряет
    # вход через Apple молча, без ошибки, у всех сразу.
    #
    # В orakul терять нечего. Вход вообще не показывается: `wheesprAvailable`
    # в AppState включается только при непустом адресе сервера, а DIST-сборка
    # выше его не бакает. Аккаунтов у orakul нет — ключ провайдера человек
    # вводит сам, и он лежит в Связке ключей. Так что останавливать сборку
    # было бы требованием профиля ради возможности, которой в продукте нет.
    #
    # Останов остаётся на один случай: если вход когда-нибудь появится
    # (адрес сервера непустой), молчаливая потеря снова станет ошибкой.
    if [ "${MEETGPT_DIST:-0}" = "1" ] && [ -n "$DIST_BACKEND" ] \
       && [ "${MEETGPT_ALLOW_NO_APPLESIGNIN:-0}" != "1" ]; then
        echo "!! сборка для распространения потеряет вход через Apple — $WHY" >&2
        echo "   Профиль Developer ID для ai.orakul.desktop с Sign in with Apple" >&2
        echo "   положить в $PROFILE и пересобрать." >&2
        echo "   Выпустить без этого намеренно: MEETGPT_ALLOW_NO_APPLESIGNIN=1" >&2
        exit 1
    fi
    echo ">> Вход через Apple: не собирается — $WHY (в orakul входа нет)"
fi

# Sign the staging bundle before installing it. Developers often launch
# the staged app directly; leaving that copy unsigned gives it a different
# TCC identity from /Applications/Cruxwing.app, so an apparently granted
# Microphone or Screen Recording permission is rejected at runtime.
codesign --force --deep --sign "$SIGN_ID" --entitlements "$SIGN_ENT" "$STAGE"
codesign --verify --deep --strict "$STAGE"

# Decide the final location only after signing, then copy the exact signed
# bundle. Both supported launch paths now have the same designated requirement.
if [ "${MEETGPT_NO_INSTALL:-0}" = "1" ]; then
    APP="$STAGE"
    echo ">> install skipped (MEETGPT_NO_INSTALL=1) — using $APP"
elif mkdir -p "$APP_DIR" 2>/dev/null && [ -w "$APP_DIR" ]; then
    APP="$DEST"
    echo ">> installing to $APP"
    rm -rf "$APP"
    cp -R "$STAGE" "$APP"
    codesign --verify --deep --strict "$APP"
    if [ "$APP_BASENAME" = "Cruxwing" ] && [ -d "$LEGACY_DEST" ]; then
        echo ">> removing legacy app wrapper $LEGACY_DEST"
        rm -rf "$LEGACY_DEST"
    fi
else
    APP="$STAGE"
    echo ">> warning: $APP_DIR not writable — using signed staging copy $APP"
    echo "   (to install: sudo cp -R \"$STAGE\" \"$APP_DIR/\")"
fi

# Refresh the icon cache so Finder/Dock pick up the new icon immediately.
touch "$APP"

# TCC keys a Screen Recording / Microphone grant on the bundle id AND the
# signing requirement. Another bundle on this Mac with the SAME id but a
# DIFFERENT requirement — a copy from an older project still signed with the
# local self-signed cert, say — makes macOS treat the two as different apps:
# the permission prompt returns on every launch, and no amount of adding and
# removing entries in System Settings converges, because the record never
# matches the binary that actually runs. That cost a debugging session; a build
# is the moment to notice it, since a build is what creates the copies.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$BUNDLE_ID" ]; then
    OUR_REQ="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
    CONFLICTS=""
    while IFS= read -r other; do
        [ -z "$other" ] && continue
        [ "$other" = "$APP" ] && continue
        [ "$other" = "$STAGE" ] && continue     # our own staging copy, same signature
        other_req="$(codesign -d -r- "$other" 2>/dev/null | sed -n 's/^designated => //p')"
        [ "$other_req" = "$OUR_REQ" ] && continue
        CONFLICTS="$CONFLICTS  $other\n"
    done <<< "$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true)"
    if [ -n "$CONFLICTS" ]; then
        echo ">> warning: other bundles claim $BUNDLE_ID with a DIFFERENT signature:" >&2
        printf "$CONFLICTS" >&2
        echo "   Screen Recording / Microphone prompts will keep returning until they are removed." >&2
        echo "   Fix: delete them, then  tccutil reset ScreenCapture $BUNDLE_ID && tccutil reset Microphone $BUNDLE_ID" >&2
    fi
fi

echo ">> done: $APP"
echo "launch with: open \"$APP\""
