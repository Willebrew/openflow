#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const settings = fs.readFileSync(path.join(root, "openflow/Views/SettingsView.swift"), "utf8");
const flowUI = fs.readFileSync(path.join(root, "openflow/Views/FlowUI.swift"), "utf8");
const home = fs.readFileSync(path.join(root, "openflow/Views/HomeDashboardView.swift"), "utf8");
const history = fs.readFileSync(path.join(root, "openflow/Views/HistoryView.swift"), "utf8");
const dictionary = fs.readFileSync(path.join(root, "openflow/Views/DictionaryView.swift"), "utf8");
const phrases = fs.readFileSync(path.join(root, "openflow/Views/PhrasesView.swift"), "utf8");
const style = fs.readFileSync(path.join(root, "openflow/Views/StyleView.swift"), "utf8");
const apps = fs.readFileSync(path.join(root, "openflow/Views/AppsView.swift"), "utf8");
const userSettings = fs.readFileSync(path.join(root, "openflow/Models/UserSettings.swift"), "utf8");
const onboarding = fs.readFileSync(path.join(root, "openflow/Views/OnboardingFlowView.swift"), "utf8");
const privacy = fs.readFileSync(path.join(root, "openflow/Models/CloudPrivacyCopy.swift"), "utf8");
const menuBar = fs.readFileSync(path.join(root, "openflow/App/MenuBarController.swift"), "utf8");
const dictation = fs.readFileSync(path.join(root, "openflow/Models/DictationModels.swift"), "utf8");
const cloudClient = fs.readFileSync(path.join(root, "openflow/Services/OpenFlowCloudService.swift"), "utf8");
const routing = fs.readFileSync(path.join(root, "openflow/Services/OpenFlowProviderRouting.swift"), "utf8");
const pillWindow = fs.readFileSync(path.join(root, "openflow/App/FloatingDictationWindow.swift"), "utf8");

function fail(message) {
  console.error(`hub page chrome check failed: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

assert(flowUI.includes("static let hubPageHorizontalPadding: CGFloat = 18"),
       "hub pages must share 18pt horizontal padding with Home/History");
assert(flowUI.includes("static let hubPageVerticalPadding: CGFloat = 12"),
       "hub pages must share 12pt vertical padding with Home/History");
assert(flowUI.includes("static let hubTitleRowHeight: CGFloat = 26"),
       "hub titles must share a 26pt row so a trailing + cannot shift the baseline");
assert(flowUI.includes("static let overlayScrollerGutter: CGFloat = 12"),
       "inset rows must keep a 12pt trailing gutter so overlay NSScroller cannot cover 28pt actions");
assert(flowUI.includes("static let hubWindowWidth: CGFloat = 880"),
       "Flow Hub max width is the 880pt design size");
assert(flowUI.includes("static let hubWindowHeight: CGFloat = 640"),
       "Flow Hub max height is the 640pt design size");
assert(flowUI.includes("func flowHubPagePadding()"),
       "hub padding must be one named modifier, not per-tab literals");
assert(flowUI.includes("func flowHubListScroll()"),
       "hub lists must share one named hidden-indicator modifier");
assert(flowUI.includes("scrollIndicators(.hidden)"),
       "flowHubListScroll must hide overlay scroll indicators");
assert(flowUI.includes("func flowInsetRowPadding()"),
       "inset rows must share extra trailing padding for the overlay scroller");
assert(flowUI.includes("10 + FlowUI.overlayScrollerGutter"),
       "inset row trailing padding must add the 12pt overlay gutter on top of 10pt");
assert(flowUI.includes(".frame(height: FlowUI.hubTitleRowHeight"),
       "FlowCompactPageHeader must pin the title row height");

const content = settings.slice(settings.indexOf("private var content: some View"), settings.indexOf("private var home:"));
assert(content.includes("home.flowHubPagePadding()"),
       "Home must use flowHubPagePadding");
assert(content.includes("HistoryView().environmentObject(coordinator).flowHubPagePadding()"),
       "History must use flowHubPagePadding");
assert(content.includes("AppsView("),
       "View all apps must open AppsView in the hub content switch");
assert(content.includes("onBackToHome: { selectedTab = .general }"),
       "Apps must be able to return to Home without a new top-nav tab");
assert(content.includes(".flowHubPagePadding()"),
       "Apps must use flowHubPagePadding");
assert(!content.includes('topNav("Apps"'),
       "Apps must not add a sixth top-nav tab");
assert(content.includes("DictionaryView().environmentObject(coordinator).flowHubPagePadding()"),
       "Dictionary must use flowHubPagePadding");
assert(content.includes("PhrasesView().environmentObject(coordinator).flowHubPagePadding()"),
       "Phrases must use flowHubPagePadding, not a third inset");
assert(content.includes("StyleView().environmentObject(coordinator).flowHubPagePadding()"),
       "Style must use flowHubPagePadding, not a third inset");
assert(!/PhrasesView\(\)[^\n]*\.padding\(30\)/.test(content),
       "Phrases must not use the Settings 30pt inset");
assert(!/StyleView\(\)[^\n]*\.padding\(30\)/.test(content),
       "Style must not use the Settings 30pt inset");
assert(!/DictionaryView\(\)[^\n]*\.padding\(30\)/.test(content),
       "Dictionary must not use the Settings 30pt inset");
assert(!/HistoryView\(\)[^\n]*\.padding\(30\)/.test(content),
       "History must not use the Settings 30pt inset");
assert(content.includes("settingsPanel.padding(30)"),
       "Settings may keep the 30pt panel inset");
assert(settings.includes("settingsTab == .provider && !showingGroqSettings"),
       "collapsed Subscription must not wrap in a ScrollView");
assert(settings.includes("subscriptionDetail"),
       "Subscription must be one compact stack so the BYO row can sit under the plans");
assert(settings.includes("if showingGroqSettings"),
       "expanded Subscription may scroll so the paste-key UI stays reachable");
const planCardStart = settings.indexOf("private func settingsPlanCard");
const planCardEnd = settings.indexOf("private func shortcutPickerRow");
assert(planCardStart > -1 && planCardEnd > planCardStart,
       "settingsPlanCard must stay a dedicated Free/Pro card");
const planCard = settings.slice(planCardStart, planCardEnd);
assert(planCard.includes(".padding(16)"),
       "plan cards must keep 16pt inner padding so Downgrade/Manage plan sit inside the glass");
assert(!planCard.includes("minHeight: 172") && !planCard.includes("minHeight: 204"),
       "plan cards must not use a 1.0.50 clip height that lets buttons overflow");
assert(planCard.includes("Spacer(minLength: 0)"),
       "plan cards must push Current plan / Get Pro to the bottom of the shared height");
assert(planCard.includes(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"),
       "plan cards must stretch to the shared row height");
assert(planCard.includes("FlowPlanFeatureList(detail: detail)"),
       "plan cards must render features as a bullet list, not stacked paragraphs");
assert(!/\n\s*Text\(detail\)/.test(planCard),
       "plan cards must not dump feature copy as a single Text");
assert(!planCard.includes(".clipped()"),
       "plan cards must not clip Downgrade/Manage plan");
const subscriptionStart = settings.indexOf("private var subscriptionDetail");
const subscriptionEnd = settings.indexOf("private var settingsRail");
assert(subscriptionStart > -1 && subscriptionEnd > subscriptionStart,
       "subscriptionDetail must stay a dedicated collapsed stack");
const subscription = settings.slice(subscriptionStart, subscriptionEnd);
assert(subscription.includes("EqualHeightPlanRow(spacing: 12)"),
       "Free and Pro must share one equal-height row sized from the taller card");
assert(subscription.includes("VStack(alignment: .leading, spacing: 14)"),
       "collapsed Subscription must keep a 14pt gap so Bring your own key is not under the plan buttons");
assert(!/\n\s*Menu \{/.test(subscription),
       "Subscription / BYO must not put SwiftUI Menu in its scroller");
assert(subscription.indexOf("settingsPlanCard") < subscription.indexOf("Bring your own key"),
       "plan cards must sit above Bring your own key");
assert(!subscription.includes("CloudPrivacyCopy.cloudModeLeavesDevice"),
       "Subscription must not include the cloud-mode leaves-device paragraph");
assert(!subscription.toLowerCase().includes("microphone audio leaves"),
       "Subscription must not restore the cloud-mode audio disclaimer");
assert(!onboarding.includes("CloudPrivacyCopy.cloudModeLeavesDevice"),
       "onboarding must not include the cloud-mode leaves-device paragraph");
assert(!onboarding.toLowerCase().includes("microphone audio leaves"),
       "onboarding must not restore the cloud-mode audio disclaimer");
assert(!privacy.includes("cloudModeLeavesDevice"),
       "CloudPrivacyCopy must not keep the unused leaves-device string");
assert(!privacy.toLowerCase().includes("wav"),
       "Mac plan copy must not restore the WAV transcription disclaimer");
assert(subscription.includes(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"),
       "collapsed Subscription must pin to the hub height instead of growing the window");
assert(subscription.includes("CloudPrivacyCopy.proPlanDetail"),
       "Subscription Pro copy must come from CloudPrivacyCopy");
assert(privacy.includes("Unlimited usage* (subject to fair usage limits)"),
       "Pro copy must lead with unlimited usage subject to fair usage");
assert(privacy.includes("Access to generative styles"),
       "Pro copy must list access to generative styles");
assert(privacy.includes("\\nAccess to generative styles"),
       "Pro copy must be two feature lines, not one wrapped sentence");
assert(flowUI.includes("struct FlowPlanFeatureList"),
       "Free/Pro feature lines must share one typographic bullet list");
assert(flowUI.includes('"\\u{2022}"') || flowUI.includes("\\u{2022}"),
       "plan features must use a typographic bullet, not emoji");
assert(onboarding.includes("FlowPlanFeatureList(detail: detail)"),
       "onboarding plan cards must use the same feature bullet list");
assert(!privacy.includes("Pro on every Mac"),
       "Pro copy must not restore Pro on every Mac");
assert(!privacy.includes("No monthly word cap"),
       "Pro copy must not restore the word-cap sentence");
assert(!privacy.includes("Generate with openflow is Pro"),
       "Pro copy must not restore the Generate-is-Pro sentence");
assert(!privacy.includes("$6"),
       "Pro copy must not mention $6 included spend");
assert(!privacy.toLowerCase().includes("spend"),
       "Pro copy must not mention included spend");
assert(!settings.includes("$6"),
       "Settings must not mention $6 included spend");
assert(!onboarding.includes("$6"),
       "Onboarding must not mention $6 included spend");
assert(!privacy.includes("3 Mac"),
       "Pro copy must not revive the old 3 Mac cap");
assert(!privacy.includes("20,000"),
       "Settings must not dump the 20,000 request env rail");
assert(!settings.toLowerCase().includes("unlimited"),
       "Settings must not hardcode unlimited; use CloudPrivacyCopy");
assert(!onboarding.toLowerCase().includes("unlimited"),
       "Onboarding must not hardcode unlimited; use CloudPrivacyCopy");
assert(privacy.toLowerCase().includes("unlimited usage*"),
       "Plan copy must say unlimited usage with an asterisk");
assert(home.includes("HomeActivityStats.timeSavedSeconds(words: totalWords"),
       "signed-in time saved must recompute from lifetime words and audio");
assert(!home.includes("lifetime?.timeSavedSeconds"),
       "Home must not display a never-backfilled stored timeSavedSeconds gauge");
assert(home.includes("this week"),
       "time-saved percent under the lifetime gauge must be labeled this week");
assert(home.includes("return \"\\(signed) this week\""),
       "lifetime gauge percent must say this week, not imply lifetime");
const homeStats = fs.readFileSync(path.join(root, "openflow/Models/HomeActivityStats.swift"), "utf8");
assert(homeStats.includes("weekToDateDayCount"),
       "1.0.63 WTD vs same weekdays last week must stay in HomeActivityStats");
assert(homeStats.includes("Same time last week"),
       "mid-week Home percents must still label the matched weekday window");
assert(!home.includes("weekWords.lastWeek.formatted()"),
       "This week subline must not show the prior-week word count");
assert(home.includes("HomeActivityStats.weekComparisonCaption()"),
       "This week subline keeps the comparison caption beside the percent");
assert(fs.readFileSync(path.join(root, "openflow/Services/FieldTextWindow.swift"), "utf8").includes("enum FieldTextWindow"),
       "1.0.62 Mail/Notes field context must stay in FieldTextWindow");
const coordinatorSrc = fs.readFileSync(path.join(root, "openflow/Services/DictationCoordinator.swift"), "utf8");
assert(coordinatorSrc.includes("refreshCloudStatsIfSignedIn"),
       "after dictation, stats refresh must await the cloud write");
assert(coordinatorSrc.includes("if !syncedLocalActivity"),
       "cloud dictation must not GET /openflow/stats in parallel with the BYO activity write");
const beginDictation = coordinatorSrc.slice(
    coordinatorSrc.indexOf("func beginDictation"),
    coordinatorSrc.indexOf("private func attachSessionContext")
);
assert(!beginDictation.includes("revalidateStoredCloudSession()"),
       "hold-Fn must not introspect on every utterance");
assert(!beginDictation.includes("entitlement"),
       "hold-Fn must not poll Convex entitlement");
assert(!coordinatorSrc.includes("warmUpCloudSession"),
       "do not add a Convex session heartbeat");
assert(coordinatorSrc.includes("CloudSessionValidator.menuRevalidateInterval"),
       "menu-bar introspect must be debounced");
assert(coordinatorSrc.includes("RunLoop.main.add(timer, forMode: .common)"),
       "12-minute session timer must run in accessory common mode");
assert(!coordinatorSrc.includes("Timer.scheduledTimer"),
       "session timer must not use scheduledTimer default mode that stalls until hub");
assert(cloudClient.includes("if http.statusCode == 401"),
       "authenticated cloud 401 must be detected");
assert(cloudClient.includes("throw OpenflowError.cloudSessionRevoked"),
       "cloud 401 with a token must be cloudSessionRevoked");
assert(coordinatorSrc.includes("_ = await consumeCloudSessionError(error)"),
       "pill dictation catch must revoke on cloudSessionRevoked");
assert(coordinatorSrc.includes("confirmRemoteCloudRevocation"),
       "Convex 401 must re-check nql-auth before deleting the cloud token");
assert(flowUI.includes("static let settingsDetailHeaderInset: CGFloat = 24"),
       "Settings detail headers must share a 24pt inset with General");
assert(flowUI.includes("static let settingsDetailHeaderIconSize: CGFloat = 30"),
       "Settings detail headers must share a 30pt icon frame");
assert(flowUI.includes("static let settingsDetailHeaderIconFont: CGFloat = 15"),
       "Settings detail headers must share a 15pt icon font");
assert(flowUI.includes("static let settingsDetailHeaderTitleFont: CGFloat = 22"),
       "Settings detail headers must share a 22pt bold title");
assert(flowUI.includes("static let settingsDetailHeaderIconTitleGap: CGFloat = 11"),
       "Settings detail headers must share an 11pt icon-to-title gap");
assert(flowUI.includes("static let settingsDetailTitleContentGap: CGFloat = 18"),
       "Settings panes must share an 18pt title-to-content gap");
assert(settings.includes("private var settingsPageHeader"),
       "all five Settings tabs must use one settingsPageHeader");
assert(settings.includes("FlowUI.settingsDetailHeaderInset"),
       "Settings detail column padding must be the shared 24pt header inset");
assert(settings.includes("FlowUI.settingsDetailHeaderIconTitleGap"),
       "Settings page header must use the shared icon-to-title gap");
assert(settings.includes("FlowUI.settingsDetailHeaderIconFont"),
       "Settings page header must use the shared 15pt icon font");
assert(settings.includes("FlowUI.settingsDetailHeaderIconSize"),
       "Settings page header must use the shared 30pt icon size");
assert(settings.includes("FlowUI.settingsDetailHeaderTitleFont"),
       "Settings page header must use the shared 22pt title font");
assert(settings.includes("spacing: FlowUI.settingsDetailTitleContentGap"),
       "every Settings pane must use the shared title-to-content gap");
assert(!settings.includes("padding(settingsTab == .provider ? 14 : 24)"),
       "Subscription must not use the 1.0.54 14pt column padding that shifted its title");
assert(!settings.includes("settingsTab == .provider ? 8 : 18"),
       "Subscription must not use the 1.0.55 8pt title-to-content gap");
const headerStart = settings.indexOf("private var settingsPageHeader");
const columnStart = settings.indexOf("private var settingsDetailColumn");
const subscriptionDetailStart = settings.indexOf("private var subscriptionDetail");
assert(headerStart > -1 && columnStart > headerStart,
       "settingsPageHeader must sit with the detail column");
assert(subscriptionDetailStart > columnStart,
       "Subscription content must come after the shared page header");
const headerBlock = settings.slice(headerStart, columnStart);
assert(headerBlock.includes("HStack(alignment: .center, spacing: FlowUI.settingsDetailHeaderIconTitleGap)"),
       "Settings page header must center the icon and title with the shared gap");
assert(!headerBlock.includes("settingsTab == .provider"),
       "settingsPageHeader must not special-case Subscription");
const columnBlock = settings.slice(columnStart, subscriptionDetailStart);
assert(columnBlock.includes(".padding(FlowUI.settingsDetailHeaderInset)"),
       "every Settings tab must pad the detail column with the shared 24pt inset");
assert(columnBlock.includes("spacing: FlowUI.settingsDetailTitleContentGap"),
       "settingsDetailColumn must use the shared 18pt title-to-content gap");
assert(!columnBlock.includes("settingsTab == .provider"),
       "settingsDetailColumn must not special-case Subscription spacing");
assert(!columnBlock.includes("provider ? 14"),
       "settingsDetailColumn must not give Subscription a different page-title inset");

assert(settings.includes("minWidth: FlowUI.hubWindowWidth"),
       "SettingsView must pin the hub to the named 880pt width");
assert(settings.includes("maxWidth: FlowUI.hubWindowWidth"),
       "SettingsView must cap the hub at 880pt so it cannot grow");
assert(settings.includes("minHeight: FlowUI.hubWindowHeight"),
       "SettingsView must pin the hub to the named 640pt height");
assert(settings.includes("maxHeight: FlowUI.hubWindowHeight"),
       "SettingsView must cap the hub at 640pt so it cannot grow");
assert(
  settings.indexOf("minWidth: FlowUI.hubWindowWidth") <
    settings.indexOf("maxWidth: FlowUI.hubWindowWidth") &&
    settings.indexOf("maxWidth: FlowUI.hubWindowWidth") <
      settings.indexOf("minHeight: FlowUI.hubWindowHeight"),
  "SwiftUI frame requires maxWidth before minHeight"
);
assert(history.includes(".flowHubListScroll()"),
       "History list must hide overlay scroll indicators");
assert(dictionary.includes(".flowHubListScroll()"),
       "Dictionary list must hide overlay scroll indicators");
assert(phrases.includes(".flowHubListScroll()"),
       "Phrases list must hide overlay scroll indicators");
assert(style.includes(".flowHubListScroll()"),
       "Style list must hide overlay scroll indicators");
assert(apps.includes(".flowHubListScroll()"),
       "Apps list must hide overlay scroll indicators");
assert(history.includes(".flowInsetRowPadding()"),
       "History rows must keep extra trailing padding");
assert(apps.includes(".flowInsetRowPadding()"),
       "Apps rows must keep extra trailing padding");
assert(style.includes(".flowInsetRowPadding()"),
       "Style library rows must keep extra trailing padding");
assert(!settings.includes("flowHubListScroll"),
       "Settings must not hide scroll indicators when BYO key is expanded");
const settingsScroller = settings.slice(
  settings.indexOf("private var settingsDetailScroller"),
  settings.indexOf("private var settingsPageHeader")
);
assert(settingsScroller.includes("ScrollView"),
       "expanded Settings may still wrap in a ScrollView");
assert(!settingsScroller.includes("scrollIndicators"),
       "Settings BYO-expanded ScrollView must keep its system scroller");
assert(menuBar.includes("contentMinSize = Self.hubContentSize"),
       "hub NSWindow must pin contentMinSize to 880x640");
assert(menuBar.includes("contentMaxSize = Self.hubContentSize"),
       "hub NSWindow must pin contentMaxSize to 880x640 so it cannot grow");
assert(menuBar.includes("setContentSize(Self.hubContentSize)"),
       "hub NSWindow must open at 880x640");
assert(!menuBar.includes("width: 1040") && !menuBar.includes("height: 680"),
       "hub must not reopen at the old 1040x680 size");
const hubConfigure = menuBar.slice(
  menuBar.indexOf("private func configureWindow(_ window: NSWindow)"),
  menuBar.indexOf("private func configureHostingView")
);
assert(!hubConfigure.includes(".resizable"),
       "hub window must not stay freely resizable past the design size");
assert(menuBar.includes("NSSize(width: 920, height: 640)"),
       "onboarding window size must stay independent of the hub lock");
assert(settings.includes("Bring your own key"),
       "BYO Groq must stay available without Pro");
assert(!settings.includes("Save raw STT text"),
       "General must not show the raw STT developer toggle");
assert(!settings.includes("$coordinator.settings.storeRawTranscript"),
       "storeRawTranscript must not be a Settings control");
assert(settings.includes("Hide inactive pill"),
       "Hide inactive pill stays a user setting");
assert(settings.includes("refreshPillVisibility()"),
       "Hide inactive pill must refresh the overlay as soon as the toggle changes");
assert(pillWindow.includes("cancelPendingHide()"),
       "pill show/hide must cancel an in-flight hide");
const pillShow = pillWindow.slice(
  pillWindow.indexOf("func show()"),
  pillWindow.indexOf("func hide(after")
);
assert(pillShow.includes("window.alphaValue = 1"),
       "show() must restore alpha even if AppKit still reports the panel visible");
assert(!pillShow.includes("if window.isVisible"),
       "show() must not skip alpha restore when isVisible is stale");

assert(home.includes("HomeActivityStats.homeTopAppCount"),
       "Home Top apps must use the shared three-row cap, not a hardcoded two");
assert(home.includes("allApps.count > topApps.count"),
       "View all must appear whenever the Apps hub has more than the Home rows");
assert(apps.includes("localApps: coordinator.history.appStats"),
       "Apps hub must keep persisted local apps instead of replacing with a shorter cloud list");
assert(apps.includes(".flowHubListScroll()"),
       "Apps list must hide overlay scroll indicators");
assert(apps.includes(".flowInsetRowPadding()"),
       "Apps rows must keep extra trailing padding");

assert(home.includes("FlowCompactPageHeader("),
       "Home must use FlowCompactPageHeader, not a one-off title stack");
assert(history.includes("FlowCompactPageHeader("),
       "History must use FlowCompactPageHeader");
assert(dictionary.includes("FlowCompactPageHeader("),
       "Dictionary must use FlowCompactPageHeader");
assert(phrases.includes("FlowCompactPageHeader("),
       "Phrases must use FlowCompactPageHeader");
assert(style.includes("FlowCompactPageHeader("),
       "Style must use FlowCompactPageHeader");
assert(apps.includes("FlowCompactPageHeader("),
       "Apps must use FlowCompactPageHeader");
assert(apps.includes("title: \"Apps\""),
       "Apps page header must be Apps");
assert(!apps.includes("FlowMossCountChip"),
       "Apps must not show a list-length count chip");
assert(apps.includes("HomeAppUsageRow"),
       "Apps rows must reuse the Home app icon, name, minutes, and moss bar");
assert(apps.includes("FlowUI.controlFill"),
       "Apps rows must use History-style inset fills");
assert(apps.includes("chevron.left"),
       "Apps may return to Home with a back control");
assert(!apps.includes("isModal") && !apps.includes("allAppsOverlay"),
       "Apps must be a real page, not a modal overlay");
assert(!home.includes("allAppsOverlay") && !home.includes("showingAllApps"),
       "Home must not dim, blur, or cover the 2x2 with an Apps overlay");
assert(!settings.includes('topNav("Apps"') && !settings.includes('nav("Apps"'),
       "do not add Apps to Home/History/Dictionary/Phrases/Style chrome");
assert(!home.includes("struct HomePageHeader") && !phrases.includes("struct PhrasePageHeader") &&
       !style.includes("struct StylePageHeader"),
       "do not invent a third page header");

assert(phrases.includes("\"plus\""),
       "Phrases must keep the Dictionary-style header plus");
assert(phrases.includes("Search phrases"),
       "Phrases search must stay full width");
assert(phrases.includes("when I say"),
       "Phrases must keep the inline composer");
assert(!phrases.includes("FlowMossCountChip"),
       "Phrases must not show a list-length count chip");
assert(style.includes("\"plus\""),
       "Style must keep the header plus");
assert(userSettings.includes('case .auto: "textformat"'),
       "Auto must use textformat, not sparkles");
assert(style.includes("text.badge.plus"),
       "Style generate must use text.badge.plus, not sparkles");
assert(style.includes("Generate with openflow"),
       "Style + must morph into a Generate with openflow choice");
assert(style.includes("chooseGeneratePath()"),
       "Generate must still have a dedicated path opener");
assert(style.includes("enabled: coordinator.canGenerateStyleWithOpenflow()"),
       "Free generate must be disabled in the choose row, not a tap that errors");
assert(style.includes("styleGenerateProRequiredMessage"),
       "disabled generate must still explain Pro in help copy");
assert(routing.includes("Generate with openflow is included with Pro"),
       "Pro-gated generate copy must stay explicit");
assert(style.includes("Write it myself"),
       "Style + must morph into a Write it myself choice");
assert(!style.includes("Generate with OpenFlow"),
       "product UI must not capitalize the name as OpenFlow");
assert(!style.includes("sparkles") && !style.includes("sparkle."),
       "Style must not use sparkle icons");
assert(!settings.includes("sparkles") && !settings.includes("sparkle."),
       "Settings must not use sparkle icons");
assert(!onboarding.includes("sparkles") && !onboarding.includes("sparkle."),
       "Onboarding must not use sparkle icons");
assert(!userSettings.includes("sparkles"),
       "style preset icons must not use sparkles");
assert(settings.includes('topNav("Home", "house", .general)'),
       "Home tab must use house, not sparkle.magnifyingglass");
assert(settings.includes('symbol: "infinity"'),
       "openflow Pro must use infinity, not sparkles");
assert(onboarding.includes('symbol: "infinity"'),
       "onboarding Pro must use infinity, not sparkles");
assert(onboarding.includes("openflow Pro"),
       "onboarding plan copy must use lowercase openflow");
assert(!onboarding.includes("OpenFlow Pro") && !onboarding.includes("OpenFlow is"),
       "onboarding must not capitalize OpenFlow in product copy");
assert(settings.includes("openflow Pro"),
       "Settings plan copy must use lowercase openflow");
assert(style.includes("Search styles"),
       "Style search must stay full width");
assert(!style.includes("FlowMossCountChip"),
       "Style must not show a list-length count chip");
assert(!style.includes("FlowMenuPicker"),
       "Style must not use FlowMenuPicker pills; those stacked unlabeled pickers with two chevrons");
assert(style.includes("Current style"),
       "Style must lead with one current/default style");
assert(style.includes("When you're in"),
       "Style context rows must be labeled as when-you're-in, not mixed into the library");
const styleBody = style.slice(style.indexOf("var body: some View"), style.indexOf(".alert("));
assert(styleBody.includes("currentStyleHero"),
       "Style body must still render the current-style hero");
assert(styleBody.indexOf("currentStyleHero") < styleBody.indexOf("When you're in"),
       "the current style must sit above context assignments");
assert(style.indexOf("Built-in") < style.indexOf("When you're in"),
       "the style library must sit above context assignments");
assert(style.indexOf("majorSectionTitle(\"Styles\")") < style.indexOf("Built-in"),
       "Styles is the library section; Built-in is a subsection, not a page header");
assert(style.includes("sectionTitle(\"Yours\")"),
       "custom styles live under Yours, not mixed with Personal/Work/Email");
assert(style.includes("checkmark.circle.fill"),
       "selected library rows must show a teal check, not only update the hero");
assert(style.includes("FlowUI.moss.opacity"),
       "selected library rows must use a moss/teal highlight");
assert(style.includes("Write it myself"),
       "Style + must morph into a Write it myself choice");
assert(style.includes("case .choose"),
       "composer must start as a choose fork, not the three-field wall");
assert(style.includes("case .generate"),
       "generate must be its own composer path");
assert(style.includes("case .manual"),
       "manual must be its own composer path");
assert(style.includes("Describe the style you want"),
       "generate path uses one describe placeholder");
assert(style.includes("placeholder: \"Style title\""),
       "name field placeholder must say Style title, not a sample style");
assert(!style.includes("Shakespearean"),
       "do not use a famous-author example as the title placeholder");
assert(style.includes("Rewrite dictation as"),
       "instructions use an example placeholder, not the word Instructions");
assert(!style.includes("composerCaption"),
       "do not pair section titles with identical placeholders");
assert(!style.includes("placeholder: \"Name\""),
       "never ship label Name plus placeholder Name");
assert(!style.includes("placeholder: \"Describe what you want\""),
       "never ship the stacked describe caption plus placeholder");
assert(!style.includes("placeholder: \"Instructions\""),
       "never ship label Instructions plus placeholder Instructions");
assert(style.includes("if isAddingStyle"),
       "creating a style must be able to hide the current-style hero");
const choiceStart = style.indexOf("private var composerChoiceRow");
const choiceEnd = style.indexOf("private var generateAskRow");
assert(choiceStart > -1 && choiceEnd > choiceStart,
       "choose row must stay a dedicated view");
const choiceBlock = style.slice(choiceStart, choiceEnd);
assert(!choiceBlock.includes("composerCancelButton"),
       "choose row must not keep an X next to Write it myself");
assert(choiceBlock.includes("enabled: coordinator.canGenerateStyleWithOpenflow()"),
       "Generate with openflow must take the Pro/BYO enabled flag");
const choiceButtonStart = style.indexOf("private func composerChoiceButton");
const choiceButtonEnd = style.indexOf("private var composerCancelButton");
assert(choiceButtonStart > -1 && choiceButtonEnd > choiceButtonStart,
       "choice buttons must stay a dedicated helper");
const choiceButtonBlock = style.slice(choiceButtonStart, choiceButtonEnd);
assert(choiceButtonBlock.includes(".disabled(!enabled)"),
       "greyed generate must be disabled, not a tap that errors");
const askStart = style.indexOf("private var generateAskRow");
const askEnd = style.indexOf("private func namedPromptComposer");
assert(askStart > -1 && askEnd > askStart,
       "generate ask must be its own view");
const askBlock = style.slice(askStart, askEnd);
assert(!askBlock.includes("composerCancelButton"),
       "generate ask must use the header plus/X, not a second dismiss");
assert(askBlock.includes("Describe the style you want"),
       "ask row is the describe field");
assert(!askBlock.includes("stylePrompt"),
       "do not show Instructions while typing the ask");
assert(!askBlock.includes("FlowMultilineField"),
       "do not show an empty Instructions box on the ask");
assert(askBlock.includes("text.badge.plus"),
       "generate ask uses text.badge.plus, not sparkles");
assert(!askBlock.includes("sparkles"),
       "generate ask must not use sparkles");
assert(style.includes("styleName = draft.name"),
       "generate must write the generated name into Name");
assert(style.includes("stylePrompt = draft.prompt"),
       "generate must write the generated prompt into Instructions");
const generateBlockStart = style.indexOf("private func generateStyleIfPossible");
const generateBlockEnd = style.indexOf("private var selectedAppChoice");
assert(generateBlockStart > -1 && generateBlockEnd > generateBlockStart,
       "generateStyleIfPossible must stay a dedicated mapping onto Name + Instructions");
const generateBlock = style.slice(generateBlockStart, generateBlockEnd);
assert(!generateBlock.includes("askRequest ="),
       "generate must not clear or replace the user's describe text");
assert(generateBlock.includes("canGenerateStyleWithOpenflow"),
       "generate submit must refuse Free cloud before calling the server");
assert(generateBlock.includes("styleGenerateProRequiredMessage"),
       "generate submit must use the Pro-included copy, not Pro unavailable");
assert(style.includes("From:"),
       "generated review may show a one-line From request");
assert(!dictionary.includes("Describe the style you want"),
       "Dictionary composer must stay term → expansion, not the Style generate fields");
assert(!dictionary.includes("Generate with openflow"),
       "do not change Dictionary into the Style create fork");
assert(!phrases.includes("Generate with openflow"),
       "do not change Phrases into the Style create fork");
assert(!/\n\s*Menu \{/.test(flowUI),
       "FlowMenuPicker must not use SwiftUI Menu; Menu+fixedSize inside Settings ScrollView hangs");
assert(flowUI.includes("struct FlowPopoverChoiceList"),
       "shared assignment lists must be a popover, not NSMenu");
assert((flowUI.match(/\.popover\(/g) || []).length >= 2,
       "FlowMenuPicker and FlowSettingsMenuRow must both use popover instead of Menu");
assert(history.includes("LazyVStack") && history.includes("ForEach(filtered)"),
       "History must keep a real LazyVStack ForEach");
assert(!/\n\s*Menu \{/.test(history),
       "History must not put SwiftUI Menu in its scroll list");
assert(dictionary.includes("LazyVStack") && dictionary.includes("ForEach(filtered)"),
       "Dictionary must keep a real LazyVStack ForEach");
assert(!/\n\s*Menu \{/.test(dictionary),
       "Dictionary must not put SwiftUI Menu in its scroll list");
assert(phrases.includes("LazyVStack") && phrases.includes("ForEach(filtered)"),
       "Phrases must keep a real LazyVStack ForEach");
assert(!/\n\s*Menu \{/.test(phrases),
       "Phrases must not put SwiftUI Menu in its scroll list");
assert(apps.includes("LazyVStack") && apps.includes("ForEach(apps)"),
       "Apps must keep a real LazyVStack ForEach");
assert(!/\n\s*Menu \{/.test(apps),
       "Apps must not put SwiftUI Menu in its scroll list");
assert(!home.includes("ScrollView"),
       "ready Home must not scroll");
assert(!/\n\s*Menu \{/.test(subscription),
       "Subscription / BYO must not put SwiftUI Menu in its scroller");
assert(settings.includes("FlowMenuPicker") && flowUI.includes("FlowPopoverChoiceList"),
       "Settings microphone and shortcut pickers must share the popover list");
assert(!/\n\s*Menu \{/.test(style),
       "Style assignment must not use SwiftUI Menu; Menu+fixedSize inside ScrollView hangs the main thread");
assert(style.includes("StyleAssignmentChip"),
       "Style assignment uses a button+popover chip so NSMenu is not measured during scroll");
assert(style.includes(".popover("),
       "Style assignment uses a popover so NSMenu is not measured during scroll layout");
assert(style.includes("FlowMenuValueLabel(title:"),
       "assignment chips must show the chosen style name");
assert(style.includes("ForEach(filteredPresets)"),
       "built-in styles must be a LazyVStack ForEach, not a nested section VStack");
assert(style.includes("ForEach(filteredOverrides)"),
       "app overrides must be a LazyVStack ForEach");
assert(!style.includes("private var librarySection"),
       "do not wrap the Style library in a VStack that defeats LazyVStack");
assert(!style.includes("private var exceptionsSection"),
       "do not wrap When you're in / Specific apps in a VStack that defeats LazyVStack");
assert(!style.includes("FlowSettingsMenuRow"),
       "specific-app style pickers must show the chosen style name, not a Style Settings row");
assert(!style.includes("DisclosureGroup"),
       "Personal/Work/Email must not be DisclosureGroup headers");
assert(!style.includes("contextExceptionsCard"),
       "do not restore the lumpy grouped Settings card for Personal/Work/Email");
assert(!style.includes("emailExceptionRow"),
       "Email must not expand into a sign-off editor");
assert(!style.includes("func assignmentRow"),
       "context rows must not reuse the full-row Menu assignment that centered Personal/Work");
assert(style.includes("contextAssignmentRow"),
       "Personal/Work/Email must be identical inset assignment rows");
assert((style.match(/^\s*contextAssignmentRow\(/gm) || []).length === 3,
       "Personal, Work, and Email must share one left-aligned assignment row");
assert(style.includes("Messages, Slack, Discord, or WhatsApp"),
       "Personal caption must match messages detection");
assert(style.includes("Linear, GitHub, Notion, Notes, or AI chat"),
       "Work caption must match project/docs/AI detection");
assert(style.includes("Mail or Gmail"),
       "Email caption must match mail/gmail detection");
assert(style.includes("Same as default"),
       "Auto on a context row must say Same as default, not Auto");
assert(style.includes("symbol: \"person\""),
       "Personal must use a leading person icon");
assert(style.includes("symbol: \"briefcase\""),
       "Work must use a leading briefcase icon");
assert(style.includes("symbol: \"envelope\""),
       "Email must use a leading envelope icon");
assert(style.includes("sectionTitle(\"Specific apps\")"),
       "app overrides must stay a labeled Specific apps list");
const whenStart = style.indexOf("When you're in");
const specificApps = style.indexOf("Specific apps");
assert(whenStart > -1 && specificApps > whenStart,
       "Specific apps must sit after the when-you're-in context rows");
const contextBlock = style.slice(whenStart, specificApps);
assert(!contextBlock.includes("emailSignOffName"),
       "sign-off must not leak into Personal/Work/Email context rows");
assert(!contextBlock.includes("Sign-off"),
       "sign-off copy must not appear on context assignment rows");
assert(!contextBlock.includes("Your name on emails"),
       "email name field must not appear on Personal/Work/Email assignment rows");
assert(style.includes("emailLetterSignOffRow"),
       "sign-off belongs on the Email letter style, not the Email context");
assert(style.includes("Your name on emails"),
       "Email letter field must be labeled Your name on emails");
assert(style.includes("Optional. Email letter can end with this, e.g. Best, Will."),
       "Email letter must explain that the name is appended to sign-offs");
assert(style.includes("placeholder: \"Your name\""),
       "email name placeholder must be Your name, not a repeated label");
assert(!style.includes("Sign-off name (optional)"),
       "do not keep the opaque Sign-off name label");
assert(!style.includes("Name for Thanks / Best"),
       "do not keep the old Thanks/Best placeholder");
assert(style.indexOf("if preset == .emailLetter") < whenStart,
       "Email letter sign-off must live under Built-in, not under context assignments");
assert(style.includes("pendingDeletion = .custom"),
       "custom style trash must stage a confirm, not delete immediately");
assert(style.includes("pendingDeletion = .appOverride"),
       "app-style trash must stage a confirm, not delete immediately");
assert(style.includes("Button(\"Delete\", role: .destructive)"),
       "Style delete confirm must use a destructive Delete button");
assert(phrases.includes("pendingDeletion = phrase"),
       "phrase trash must stage a confirm, not delete immediately");
assert(phrases.includes("Button(\"Delete\", role: .destructive)"),
       "Phrases delete confirm must use a destructive Delete button");
assert(dictionary.includes("pendingDeletion = entry"),
       "dictionary trash must stage a confirm, not delete immediately");
assert(dictionary.includes("Button(\"Delete\", role: .destructive)"),
       "Dictionary delete confirm must use a destructive Delete button");
assert(history.includes("pendingDeletion = item"),
       "History row trash must stage a confirm, not delete immediately");
assert(history.includes("Button(\"Delete\", role: .destructive)"),
       "History delete confirm must use a destructive Delete button");
assert(history.includes("pendingClearAll = true"),
       "History Clear must stage a confirm, not wipe immediately");
assert(history.includes("Button(\"Clear\", role: .destructive)"),
       "History Clear confirm must use the same destructive alert as clip delete");
assert(!history.includes("Button(\"Clear\") { coordinator.history.clear() }"),
       "History Clear must not wipe on the first click");
assert(!style.includes("pendingDeletion = .choose") && !style.includes("toggleAddStyle(); pending"),
       "composer cancel must not go through delete confirm");
assert(style.includes(".frame(maxWidth: .infinity, alignment: .leading)"),
       "context title blocks must be left-aligned, never centered Menu headers");
assert(!dictation.includes("openflow Pro is unavailable"),
       "cloud HTTP failures must not be labeled as Pro unavailable");
assert(cloudClient.includes("style_generate_pro_required"),
       "cloud client must map generate-style Pro rejects");
assert(cloudClient.includes("style_generate_unavailable"),
       "cloud client must map generate-style provider failures without Pro copy");
assert(routing.includes("canGenerateStyleWithOpenflow"),
       "generate access lives next to BYO vs cloud routing");

console.log("hub page chrome checks passed");
