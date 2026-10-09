#define WLR_USE_UNSTABLE

#include <unistd.h>

#include <any>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/config/shared/parserUtils/ParserUtils.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/desktop/rule/windowRule/WindowRuleEffectContainer.hpp>
#include <hyprland/src/config/lua/bindings/LuaBindingsInternal.hpp>
#include <hyprland/src/config/lua/types/LuaConfigColor.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <hyprutils/string/VarList.hpp>

#include <algorithm>

#include "barDeco.hpp"
#include "globals.hpp"
#include "edgeSnap.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

// Do NOT change this function.
APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }

static void onNewWindow(PHLWINDOW window) {
  if (!window->m_X11DoesntWantBorders) {
    if (std::ranges::any_of(window->m_windowDecorations, [](const auto &d) { return d->getDisplayName() == "Hyprbar"; }))
      return;

    auto bar = makeUnique<COmarchyFloatingHyprBar>(window);
    g_pOmarchyFloatingGlobalState->bars.emplace_back(bar);
    bar->m_self = bar;
    HyprlandAPI::addWindowDecoration(OMARCHY_FLOATING_PHANDLE, window, std::move(bar));
  }
}

static void onPreConfigReload() {
  omarchyFloatingSnapReset();
  g_pOmarchyFloatingGlobalState->buttons.clear();
}

static void onConfigReloaded() {
  for (auto &b : g_pOmarchyFloatingGlobalState->bars) {
    if (!b)
      continue;

    b->onConfigReloaded();
  }
}

static void onUpdateWindowRules(PHLWINDOW window) {
  const auto BARIT = std::find_if(g_pOmarchyFloatingGlobalState->bars.begin(), g_pOmarchyFloatingGlobalState->bars.end(),
                                  [window](const auto &bar) { return bar->getOwner() == window; });

  if (BARIT == g_pOmarchyFloatingGlobalState->bars.end())
    return;

  (*BARIT)->updateRules();
  window->updateWindowDecos();
}

Hyprlang::CParseResult onNewOmarchyFloatingButton(const char *K, const char *V) {
  std::string v = V;
  Hyprutils::String::CVarList vars(v);

  Hyprlang::CParseResult result;

  // hyprbars-button = bgcolor, size, icon, action, fgcolor

  if (vars[0].empty() || vars[1].empty()) {
    result.setError("bgcolor and size cannot be empty");
    return result;
  }

  float size = 10;
  try {
    size = std::stof(vars[1]);
  } catch (std::exception &e) {
    result.setError("failed to parse size");
    return result;
  }

  bool userfg = false;
  auto fgcolor = Config::ParserUtils::parseColor("rgb(ffffff)");
  auto bgcolor = Config::ParserUtils::parseColor(vars[0]);

  if (!bgcolor) {
    result.setError("invalid bgcolor");
    return result;
  }

  if (vars.size() == 5) {
    userfg = true;
    fgcolor = Config::ParserUtils::parseColor(vars[4]);
  }

  if (!fgcolor) {
    result.setError("invalid fgcolor");
    return result;
  }

  g_pOmarchyFloatingGlobalState->buttons.push_back(SOmarchyFloatingHyprButton{vars[3], userfg, *fgcolor, *bgcolor, size, vars[2]});

  for (auto &b : g_pOmarchyFloatingGlobalState->bars) {
    b->m_bButtonsDirty = true;
  }

  return result;
}

int newOmarchyFloatingLuaButton(lua_State *L) {
  if (!lua_istable(L, 1))
    return Config::Lua::Bindings::Internal::configError(L, "add_button: expected a table { bg_color, fg_color, size, icon, action }");

  SOmarchyFloatingHyprButton button;

  {
    Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

    lua_getfield(L, 1, "bg_color");

    Config::Lua::CLuaConfigColor parser(0);
    auto err = parser.parse(L);
    if (err.errorCode != Config::Lua::PARSE_ERROR_OK)
      return Config::Lua::Bindings::Internal::configError(L, "add_button: failed to parse bg_color");

    button.bgcol = parser.parsed();
  }

  {
    Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

    lua_getfield(L, 1, "fg_color");

    Config::Lua::CLuaConfigColor parser(0);
    auto err = parser.parse(L);
    if (err.errorCode != Config::Lua::PARSE_ERROR_OK)
      return Config::Lua::Bindings::Internal::configError(L, "add_button: failed to parse fg_color");

    button.userfg = true;
    button.fgcol = parser.parsed();
  }

  {
    Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

    lua_getfield(L, 1, "size");

    if (!lua_isnumber(L, -1))
      return Config::Lua::Bindings::Internal::configError(L, "add_button: size must be an integer");

    button.size = lua_tointeger(L, -1);
  }

  {
    Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

    lua_getfield(L, 1, "icon");

    if (!lua_isstring(L, -1))
      return Config::Lua::Bindings::Internal::configError(L, "add_button: icon must be a string");

    button.icon = lua_tostring(L, -1);
  }

  {
    Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

    lua_getfield(L, 1, "action");

    if (!lua_isstring(L, -1))
      return Config::Lua::Bindings::Internal::configError(L, "add_button: action must be a string");

    button.cmd = lua_tostring(L, -1);
  }

  g_pOmarchyFloatingGlobalState->buttons.push_back(std::move(button));

  for (auto &b : g_pOmarchyFloatingGlobalState->bars) {
    b->m_bButtonsDirty = true;
  }

  return 0;
}

static PLUGIN_DESCRIPTION_INFO initializeOmarchyFloating(HANDLE handle) {
  OMARCHY_FLOATING_PHANDLE = handle;

  const std::string HASH = __hyprland_api_get_hash();
  const std::string CLIENT_HASH = __hyprland_api_get_client_hash();

  if (HASH != CLIENT_HASH) {
    HyprlandAPI::addNotification(OMARCHY_FLOATING_PHANDLE,
                                 "[hyprbars] Failure in initialization: Version mismatch (headers ver is not equal to running hyprland ver)",
                                 CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
    throw std::runtime_error("[hb] Version mismatch");
  }

  g_pOmarchyFloatingGlobalState = makeUnique<SOmarchyFloatingGlobalState>();
  g_pOmarchyFloatingGlobalState->nobarRuleIdx = Desktop::Rule::windowEffects()->registerEffect("hyprbars:no_bar");
  g_pOmarchyFloatingGlobalState->barColorRuleIdx = Desktop::Rule::windowEffects()->registerEffect("hyprbars:bar_color");
  g_pOmarchyFloatingGlobalState->titleColorRuleIdx = Desktop::Rule::windowEffects()->registerEffect("hyprbars:title_color");

  static auto P = Event::bus()->m_events.window.open.listen([&](PHLWINDOW w) { onNewWindow(w); });
  static auto P3 = Event::bus()->m_events.window.updateRules.listen([&](PHLWINDOW w) { onUpdateWindowRules(w); });

  g_pOmarchyFloatingGlobalState->config.barColor = makeShared<Config::Values::CColorValue>("plugin:hyprbars:bar_color", "Change the bar color", 0x88333333);
  g_pOmarchyFloatingGlobalState->config.textColor = makeShared<Config::Values::CColorValue>("plugin:hyprbars:col.text", "Change the text color", 0xffffffff);
  g_pOmarchyFloatingGlobalState->config.inactiveBarColor =
      makeShared<Config::Values::CColorValue>("plugin:hyprbars:bar_color_inactive", "Inactive title bar color; transparent means use bar_color", 0x00000000);
  g_pOmarchyFloatingGlobalState->config.inactiveButtonColor = makeShared<Config::Values::CColorValue>(
      "plugin:hyprbars:inactive_button_color", "Change the inactive button's color. 0x00000000 means unset", 0x00000000);
  g_pOmarchyFloatingGlobalState->config.barHeight = makeShared<Config::Values::CIntValue>("plugin:hyprbars:bar_height", "Change the bar's height", 15);
  g_pOmarchyFloatingGlobalState->config.barTextSize = makeShared<Config::Values::CIntValue>("plugin:hyprbars:bar_text_size", "Change the bar's text size", 10);
  g_pOmarchyFloatingGlobalState->config.barTextWeight =
      makeShared<Config::Values::CFontWeightValue>("plugin:hyprbars:bar_text_weight", "Bar's title text weight (e.g. \"bold\" or an integer 100-1000)", 400);
  g_pOmarchyFloatingGlobalState->config.barTitleEnabled =
      makeShared<Config::Values::CBoolValue>("plugin:hyprbars:bar_title_enabled", "Whether to enable titles in the bar", true);
  g_pOmarchyFloatingGlobalState->config.barBlur =
      makeShared<Config::Values::CBoolValue>("plugin:hyprbars:bar_blur", "Whether to enable blur of the bar", false);
  g_pOmarchyFloatingGlobalState->config.barTextFont = makeShared<Config::Values::CStringValue>("plugin:hyprbars:bar_text_font", "Bar's text font", "Sans");
  g_pOmarchyFloatingGlobalState->config.barTextAlign =
      makeShared<Config::Values::CStringValue>("plugin:hyprbars:bar_text_align", "Bar's text alignment", "center");
  g_pOmarchyFloatingGlobalState->config.barPartOfWindow =
      makeShared<Config::Values::CBoolValue>("plugin:hyprbars:bar_part_of_window", "Whether the bar is a part of the window (reserves space)", true);
  g_pOmarchyFloatingGlobalState->config.barPrecedenceOverBorder =
      makeShared<Config::Values::CBoolValue>("plugin:hyprbars:bar_precedence_over_border", "Whether the bar is before, or after the border", false);
  g_pOmarchyFloatingGlobalState->config.barButtonsAlignment =
      makeShared<Config::Values::CStringValue>("plugin:hyprbars:bar_buttons_alignment", "Alignment of the bar buttons", "right");
  g_pOmarchyFloatingGlobalState->config.barPadding = makeShared<Config::Values::CIntValue>("plugin:hyprbars:bar_padding", "Padding of the bar", 7);
  g_pOmarchyFloatingGlobalState->config.barButtonPadding =
      makeShared<Config::Values::CIntValue>("plugin:hyprbars:bar_button_padding", "Padding of the bar buttons", 5);
  g_pOmarchyFloatingGlobalState->config.buttonRounding =
      makeShared<Config::Values::CIntValue>("plugin:hyprbars:button_rounding", "Button corner radius. -1 preserves the upstream circular style", -1);
  g_pOmarchyFloatingGlobalState->config.buttonBorderSize =
      makeShared<Config::Values::CIntValue>("plugin:hyprbars:button_border_size", "Width of the button border", 0);
  g_pOmarchyFloatingGlobalState->config.buttonBorderColor =
      makeShared<Config::Values::CColorValue>("plugin:hyprbars:button_border_color", "Color of the button border", 0x00000000);
  g_pOmarchyFloatingGlobalState->config.enabled = makeShared<Config::Values::CBoolValue>("plugin:hyprbars:enabled", "Whether bars are enabled", true);
  g_pOmarchyFloatingGlobalState->config.iconOnHover =
      makeShared<Config::Values::CBoolValue>("plugin:hyprbars:icon_on_hover", "Whether to use an icon on hover of the buttons", false);
  g_pOmarchyFloatingGlobalState->config.onDoubleClick =
      makeShared<Config::Values::CStringValue>("plugin:hyprbars:on_double_click", "Action to execute on double click of the bar", "");
  g_pOmarchyFloatingGlobalState->config.workspaceTag =
      makeShared<Config::Values::CStringValue>("plugin:hyprbars:workspace_tag", "Restrict bars and snapping to floating windows with this tag", "");
  g_pOmarchyFloatingGlobalState->config.edgeSnap =
      makeShared<Config::Values::CBoolValue>("plugin:hyprbars:edge_snap", "Snap dragged floating windows at monitor edges", false);
  g_pOmarchyFloatingGlobalState->config.edgeThreshold =
      makeShared<Config::Values::CIntValue>("plugin:hyprbars:edge_threshold", "Edge activation distance in logical pixels", 24);
  g_pOmarchyFloatingGlobalState->config.snapGap =
      makeShared<Config::Values::CIntValue>("plugin:hyprbars:snap_gap", "Outer and center spacing in logical pixels", 8);

  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barColor);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.textColor);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.inactiveBarColor);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.inactiveButtonColor);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barHeight);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barTextSize);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barTextWeight);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barTitleEnabled);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barBlur);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barTextFont);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barTextAlign);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barPartOfWindow);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barPrecedenceOverBorder);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barButtonsAlignment);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barPadding);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.barButtonPadding);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.buttonRounding);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.buttonBorderSize);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.buttonBorderColor);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.enabled);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.workspaceTag);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.iconOnHover);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.onDoubleClick);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.edgeSnap);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.edgeThreshold);
  HyprlandAPI::addConfigValueV2(OMARCHY_FLOATING_PHANDLE, g_pOmarchyFloatingGlobalState->config.snapGap);

  omarchyFloatingSnapInit();

  if (Config::mgr()->type() == Config::CONFIG_LEGACY)
    HyprlandAPI::addConfigKeyword(OMARCHY_FLOATING_PHANDLE, "plugin:hyprbars:hyprbars-button", onNewOmarchyFloatingButton, Hyprlang::SHandlerOptions{});
  else
    HyprlandAPI::addLuaFunction(OMARCHY_FLOATING_PHANDLE, "hyprbars", "add_button", ::newOmarchyFloatingLuaButton);
  static auto P4 = Event::bus()->m_events.config.preReload.listen([&] { onPreConfigReload(); });
  static auto P5 = Event::bus()->m_events.config.reloaded.listen([&] { onConfigReloaded(); });

  // add deco to existing windows
  for (auto &w : Desktop::windowState()->windows()) {
    if (w->isHidden() || !w->m_isMapped)
      continue;

    onNewWindow(w);
  }

  HyprlandAPI::reloadConfig();

  return {"hyprbars", "A plugin to add title bars to windows.", "Vaxry", "1.0"};
}

static void exitOmarchyFloating() {
  omarchyFloatingSnapExit();
  for (auto &m : State::monitorState()->monitors())
    m->m_scheduledRecalc = true;

  g_pHyprRenderer->m_renderPass.removeAllOfType("COmarchyFloatingBarPassElement");

  Desktop::Rule::windowEffects()->unregisterEffect(g_pOmarchyFloatingGlobalState->barColorRuleIdx);
  Desktop::Rule::windowEffects()->unregisterEffect(g_pOmarchyFloatingGlobalState->titleColorRuleIdx);
  Desktop::Rule::windowEffects()->unregisterEffect(g_pOmarchyFloatingGlobalState->nobarRuleIdx);
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) { return initializeOmarchyFloating(handle); }
APICALL EXPORT void PLUGIN_EXIT() { exitOmarchyFloating(); }
