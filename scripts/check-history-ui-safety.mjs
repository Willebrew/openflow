#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const history = fs.readFileSync(path.join(root, "openflow/Views/HistoryView.swift"), "utf8");
const dictionary = fs.readFileSync(path.join(root, "openflow/Views/DictionaryView.swift"), "utf8");
const flowUI = fs.readFileSync(path.join(root, "openflow/Views/FlowUI.swift"), "utf8");
const home = fs.readFileSync(path.join(root, "openflow/Views/HomeDashboardView.swift"), "utf8");
const apps = fs.readFileSync(path.join(root, "openflow/Views/AppsView.swift"), "utf8");
const settings = fs.readFileSync(path.join(root, "openflow/Views/SettingsView.swift"), "utf8");

function fail(message) {
  console.error(`history UI safety check failed: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

assert(history.includes("ScrollView"), "History must remain a scrolling list of clips");
assert(history.includes("LazyVStack"), "History clips must list in a stack, not one non-scrolling page");
assert(history.includes("FlowSearchField"), "History search must stay");
assert(history.includes("Clear"), "History clear must stay");
assert(history.includes("coordinator.history.delete"), "History must keep per-clip delete");
assert(history.includes("pendingDeletion = item"),
       "History trash must ask before deleting a clip");
assert(history.includes("This can’t be undone."),
       "History delete confirm must warn that it cannot be undone");
assert(history.includes("pendingClearAll = true"),
       "History Clear must stage a confirm, not wipe immediately");
assert(history.includes("Button(\"Clear\", role: .destructive)"),
       "History Clear confirm must use the same destructive alert pattern as clip delete");
assert(history.includes("coordinator.history.clear()"),
       "History Clear confirm must still wipe local history");
assert(!history.includes("Button(\"Clear\") { coordinator.history.clear() }"),
       "History Clear must not wipe on the first click");
assert(history.includes("AppIconBadge"), "History rows must show the app icon like last clip");
assert(history.includes("size: 22"), "History row icon density must match last clip (22pt)");
assert(history.includes("cornerRadius: 10"), "History rows must use the last-clip inset radius");
assert(history.includes("FlowUI.controlFill"), "History rows must use the last-clip inset fill");
assert(history.includes("FlowUI.moss"), "History accent must reuse FlowUI.moss, not a second green");
assert(!history.includes("Color(red: 0.") && !history.includes("Color.green") && !history.includes("Color.mint"),
       "History must not invent a second accent color");
assert(history.includes("item.finalText"), "History copy must use finalText like last clip and the menu");
assert(history.includes("NSPasteboard.general.setString"), "History copy must write the clip to the pasteboard");
assert(history.includes("NSPasteboard.general.clearContents"), "History copy must clear the pasteboard first");
assert(history.includes("doc.on.doc"), "History copy control must match last-clip copy");
assert(!history.includes("item.metrics"), "History must not show latency or debug metrics");
assert(!history.includes("LatencyMetrics"), "History must not surface latency types");
assert(!history.includes("hotkeyToRecordingStart"), "History must not show recording-start latency");
assert(!history.includes("uploadAndTranscriptionTime"), "History must not show transcription latency");
assert(!history.includes("rawTranscript"), "History UI must not show raw STT debug text");
assert(!history.includes("play.fill") && !history.includes("AVAudioPlayer") && !history.includes("AudioPlayer"),
       "History must not add play/audio UI");
assert(!history.includes("FlowEmptyState"), "History empty state must match quiet Home emptiness, not the old empty slab");
assert(history.includes("No dictations yet") || history.includes("to dictate."),
       "empty History should stay quiet like Home last clip");
assert(!history.includes("styleChip"), "History must not show Auto / Prompt mode chips");
assert(!history.includes("item.stylePreset"), "History rows must not render style presets");
assert(!history.includes("  |  "), "History must not join time and snippet with a pipe");
assert(history.includes("timestampColumnWidth"), "History time must use a reserved column so snippets share an X");
assert(history.includes("HStack(alignment: .center, spacing: 10)"),
       "History rows must vertically center icon, snippet, and actions");
assert(!history.includes("VStack(alignment: .leading, spacing: 2)"),
       "do not stack app name above the snippet; that sits the transcription on the bottom");
assert(history.includes("monospacedDigit()"), "History time must use tabular digits");
assert(home.includes("copyLatestClip"), "last clip remains the copy-path reference");
assert(home.includes("HStack(alignment: .center, spacing: 10)"),
       "Last clip must vertically center icon, snippet, timestamp, and copy like History");
assert(!home.includes("VStack(alignment: .leading, spacing: 2)"),
       "do not stack Last clip app name above the snippet; that sits the transcription on the bottom");
assert(!home.includes("alignment: .firstTextBaseline, spacing: 10"),
       "Last clip must not baseline-stack timestamp under the app name");
assert(!home.includes("from hold"), "Home footer must not say from hold");
assert(!home.includes("  |  "), "Home last clip must not join time and snippet with a pipe");
assert(home.includes("formattedAxisTick"), "week chart Y-axis must use compact one-line tick labels");
assert(home.includes("axisLabelColumnWidth"), "week chart Y-axis column must be a named width, not the old 22pt wrap");
assert(!home.includes(".frame(width: 22, height: height"), "week chart Y-axis must be wider than 22pt");
assert(home.includes("HomeWeekChartGrid"), "week chart must draw baseline hairlines behind the bars");
assert(home.includes("gridLineOpacity"), "week chart hairlines must stay a named low-contrast opacity");
assert(home.includes("weekdayGutter"), "week chart plot height must reserve the weekday row so lines do not grow the card");
assert(home.includes("Canvas"), "week chart hairlines must draw in the same chart pass, behind the bars");
assert(!home.includes("verticalGrid"), "week chart must not add a vertical grid");
assert(flowUI.includes("static let moss"), "FlowUI.moss is the shared teal accent");
assert(flowUI.includes("static let controlCornerRadius: CGFloat = 10"),
       "search fields and toolbar buttons must share a 10pt corner radius");
assert(flowUI.includes("static let controlHeight: CGFloat = 40"),
       "toolbar Add/Save/Clear must match the 40pt search field height");
assert(!flowUI.includes(".background(background, in: Capsule())"),
       "toolbar primary/secondary buttons must not use Capsule next to search fields");
assert(history.includes("FlowCompactPageHeader"),
       "History must keep the compact page header");
assert(!history.includes("FlowMossCountChip"),
       "History must not show a list-length count chip");
assert(!history.includes("countNoun"),
       "History must not pass a count noun into the page header");
assert(!history.includes("count: coordinator.history"),
       "History must not pass item count into the page header");
assert(!history.includes("alignment: .firstTextBaseline, spacing: 8"),
       "History title must not baseline-align a raw count as a superscript");
assert(dictionary.includes("FlowCompactPageHeader"),
       "Dictionary must keep the compact page header");
assert(dictionary.includes("Search dictionary"),
       "Dictionary search must stay full width");
assert(dictionary.includes("word or phrase"),
       "Dictionary add must use an inline composer, not a detached card");
assert(dictionary.includes("expands to"),
       "Dictionary composer must have an expansion field");
assert(dictionary.includes("\"plus\""),
       "Dictionary add control must be a header plus");
assert(!dictionary.includes("FlowPrimaryButtonStyle"),
       "Dictionary must not put an Add/Save button beside search");
assert(!dictionary.includes("FlowCompactGlassCard"),
       "Dictionary must not use a detached add/edit card");
assert(!dictionary.includes("FlowMossCountChip"),
       "Dictionary must not show a list-length count chip");
assert(!dictionary.includes("countNoun"),
       "Dictionary must not pass a count noun into the page header");
assert(!flowUI.includes("FlowMossCountChip(count: count)"),
       "page headers must not render list-length count chips");
assert(home.includes("homeCardTitle"),
       "Home cards must share one title row so the 2x2 top baseline lines up");
assert(home.includes("homeCardTitle(\"Time saved\", symbol: \"waveform\")"),
       "Time saved title must keep the waveform icon on the shared title row");
assert(home.includes("homeCardTitle(\"This week\", symbol: \"calendar\")"),
       "This week title must use a calendar icon on the shared title row");
assert(home.includes("homeCardTitle(\"Top apps\", symbol: \"square.grid.2x2\")"),
       "Top apps title must use a grid icon on the shared title row");
assert(home.includes("homeCardTitle(\"Last clip\", symbol: \"doc.on.clipboard\")"),
       "Last clip title must use a clipboard icon on the shared title row");
assert(home.includes(".font(.system(size: 14, weight: .semibold))"),
       "Home card titles must be 14pt so the 2x2 glass fills without wrapping");
assert(home.includes(".frame(height: 18, alignment: .leading)"),
       "Home card titles must share an 18pt row so icons and titles stay aligned");
assert(home.includes(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"),
       "Home 2x2 rows must top-align equal-height cards");
assert(!home.includes("alignment: .firstTextBaseline, spacing: 8"),
       "This week number must not sit on the title baseline and fight Last week");
assert(home.includes("Button(\"View all apps →\", action: onOpenApps)"),
       "View all apps must open a dedicated Apps hub page, not History");
assert(!home.includes("allAppsOverlay"),
       "View all apps must not cover Home with an overlay");
assert(!home.includes("showingAllApps"),
       "View all apps must not keep an in-place modal on Home");
assert(home.includes("Button(\"View history →\", action: onOpenHistory)"),
       "Last clip View history may still open History");
assert(apps.includes("title: \"Apps\""),
       "View all apps must open a page titled Apps");
assert(apps.includes("onBackToHome"),
       "Apps must be able to return to Home");
assert(settings.includes("selectedTab = .apps"),
       "View all apps must navigate in-hub, not overlay Home");
assert(!settings.includes('topNav("Apps"'),
       "Apps must not become a top-nav tab");

console.log("history UI safety checks passed");
