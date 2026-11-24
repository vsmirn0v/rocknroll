#!/bin/bash
set -euo pipefail
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(dirname -- "$source_dir")"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-library.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
core_dir="${NATIVE_GUEST_CORE_BUILD_DIR:-$repo_dir/.build/native-guest/library-core}"
swift build --package-path "$repo_dir/ConferenceCore" --scratch-path "$core_dir" --product ConferenceCore
core_products="$(swift build --package-path "$repo_dir/ConferenceCore" --scratch-path "$core_dir" --show-bin-path)"
sources=("$build_dir/LocalizationShim.swift" "$repo_dir/MeetingEngine/Sources/MeetingEngine/Auth/SiteClientIdentityRegistry.swift" "$repo_dir/MeetingEngine/Sources/MeetingEngine/Auth/SiteTLSDelegate.swift" "$repo_dir/MeetingEngine/Sources/MeetingEngine/Providers/Guest/AdditionalRootTrust.swift" "$repo_dir/MeetingEngine/Sources/MeetingEngine/Providers/Guest/VendorEndpointResolver.swift" "$repo_dir/MeetingEngine/Sources/MeetingEngine/Providers/Guest/GuestSiteLinkAdapter.swift")
cat > "$build_dir/LocalizationShim.swift" <<'EOF'
import ConferenceCore
import Foundation

func L(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.text(key, arguments: arguments)
}
EOF
for name in RoomHistoryStore RoomSyncCoordinator CloudRoomTransport AppleCalendarReader CalendarMeetingStore CalendarInvitationContext CalendarReminderRepository CalendarReminderCoordinator CalendarReminderNotifications ReminderProfileCloud MeetingContinuationCloud MeetingContinuationCoordinator MeetingSetupCoordinator HomeMeetingCard; do
    sources+=("$repo_dir/RockNRoll/$name.swift")
done
swiftc -swift-version 5 -parse-as-library -I "$core_products" -L "$core_products" -lConferenceCore \
    "${sources[@]}" "$source_dir"/Data/*.swift "$source_dir/Tests/NativeDesktopLibraryTests.swift" \
    -o "$build_dir/native-library-tests"
cp -R "$core_products/ConferenceCore_ConferenceCore.bundle" "$build_dir/"
"$build_dir/native-library-tests"
