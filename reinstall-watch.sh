#!/bin/zsh
# Reinstala las apps de la watch (firma gratuita expira cada 7 días).
# Uso: ./reinstall-watch.sh            → OpenClock + HermesClock
#      ./reinstall-watch.sh claude     → incluye también ClaudeClock
set -e

PROJECT="/Users/cereal/Developer/openclock/OpenClock/OpenClock.xcodeproj"
WATCH_UDID="00008301-8886990914FBC02E"          # destino de build
WATCH_COREDEVICE="E24E8B76-AC46-5598-8AC3-7AF4F3D4FBB1"  # destino de instalación
DERIVED="$HOME/Library/Caches/openclock-build"

SCHEMES=("OpenClock Watch App" "HermesClock Watch App")
[[ "$1" == "claude" ]] && SCHEMES+=("ClaudeClock Watch App")

echo "→ Verificando conexión con la watch..."
STATE=$(xcrun devicectl device info details --device "$WATCH_COREDEVICE" 2>/dev/null | grep -o "tunnelState: [a-z]*" || true)
if [[ "$STATE" != "tunnelState: connected" ]]; then
    echo "⚠️  La watch no está conectada ($STATE)."
    echo "   Enciende el Wi-Fi del Mac, pon la watch en el cargador y abre Xcode → Devices (⇧⌘2)."
    exit 1
fi
echo "✓ Watch conectada."

for SCHEME in "${SCHEMES[@]}"; do
    echo ""
    echo "→ Compilando $SCHEME..."
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "platform=watchOS,id=$WATCH_UDID" \
        -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates build -quiet
    echo "→ Instalando $SCHEME en la watch..."
    xcrun devicectl device install app --device "$WATCH_COREDEVICE" \
        "$DERIVED/Build/Products/Debug-watchos/$SCHEME.app" > /dev/null
    echo "✓ $SCHEME instalada."
done

echo ""
echo "🎉 Listo. Firmas válidas por 7 días más (hasta $(date -v+7d '+%d de %B'))."
