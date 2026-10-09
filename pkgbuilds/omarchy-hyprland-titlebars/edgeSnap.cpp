#include "edgeSnap.hpp"
#include "globals.hpp"

#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/KeybindManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <algorithm>
#include <unordered_map>

namespace {
PHLWINDOWREF dragged;
CBox originalBox;
CBox snapBox;
std::string zone;
std::string preview;
std::unordered_map<PHLWINDOWREF, CBox> restoreBoxes;
std::vector<CHyprSignalListener> listeners;

void hidePreview() {
  if (!preview.empty())
    g_pEventManager->postEvent({"omarchy_snap_preview", ",none,0,0,0,0"});
  preview.clear();
  zone.clear();
}

bool enabled() { return g_pOmarchyFloatingGlobalState->config.enabled->value() && g_pOmarchyFloatingGlobalState->config.edgeSnap->value(); }

void updatePreview(const Vector2D &cursor) {
  const auto &drag = g_layoutManager->dragController();
  const auto target = drag->target();
  if (!enabled() || drag->mode() != MBIND_MOVE || !target || !target->floating() || !validMapped(target->window())) {
    omarchyFloatingSnapReset();
    return;
  }

  const auto window = target->window();
  const auto workspaceTag = g_pOmarchyFloatingGlobalState->config.workspaceTag->value();
  if (!workspaceTag.empty() && !window->m_ruleApplicator->m_tagKeeper.isTagged(workspaceTag)) {
    omarchyFloatingSnapReset();
    return;
  }
  if (dragged != window) {
    dragged = window;
    originalBox = target->position();
  }

  const auto monitor = State::monitorState()->query().vec(cursor).run();
  if (!monitor) {
    hidePreview();
    return;
  }

  const auto work = monitor->logicalBoxMinusReserved();
  const auto threshold = std::clamp<int>(g_pOmarchyFloatingGlobalState->config.edgeThreshold->value(), 1, 100);
  const auto gap = std::clamp<int>(g_pOmarchyFloatingGlobalState->config.snapGap->value(), 0, 100);
  std::string nextZone;
  if (cursor.y <= work.y + threshold)
    nextZone = "maximize";
  else if (cursor.x <= monitor->m_position.x + threshold)
    nextZone = "left";
  else if (cursor.x >= monitor->m_position.x + monitor->m_size.x - threshold)
    nextZone = "right";

  if (nextZone.empty()) {
    hidePreview();
    return;
  }

  auto box = nextZone == "maximize" ? work : work.copy().expand(-gap);
  if (nextZone != "maximize") {
    box.w = std::floor((work.w - 3 * gap) / 2.0);
    if (nextZone == "right")
      box.x = work.x + work.w - gap - box.w;
  }

  const auto reserved = window->getFullWindowReservedArea();
  const auto min = target->minSize().value_or(Vector2D{1, 1});
  // Applications with a larger minimum cannot occupy a half without overlap.
  // Keep their free placement instead of previewing geometry we cannot honor.
  if (nextZone != "maximize" && (box.w - reserved.topLeft.x - reserved.bottomRight.x < min.x || box.h - reserved.topLeft.y - reserved.bottomRight.y < min.y)) {
    hidePreview();
    return;
  }

  zone = nextZone;
  snapBox = box;
  const auto next = std::format("{},{},{:.0f},{:.0f},{:.0f},{:.0f}", monitor->m_name, zone, box.x, box.y, box.w, box.h);
  if (next != preview) {
    preview = next;
    g_pEventManager->postEvent({"omarchy_snap_preview", preview});
  }
}

void release(IPointer::SButtonEvent event) {
  if (event.button != BTN_LEFT || event.state != WL_POINTER_BUTTON_STATE_RELEASED)
    return;

  const auto window = dragged.lock();
  const auto target = g_layoutManager->dragController()->target();
  const auto nextZone = zone;
  const auto box = snapBox;
  const auto before = originalBox;
  const bool commit =
      enabled() && validMapped(window) && target && target->window() == window && g_layoutManager->dragController()->mode() == MBIND_MOVE && !nextZone.empty();
  omarchyFloatingSnapReset();
  if (!commit)
    return;

  // End the native drag before changing geometry, otherwise its final motion
  // overwrites the snap. The titlebar's release handler is idempotent.
  g_pKeybindManager->changeMouseBindMode(MBIND_INVALID);
  if (nextZone == "maximize") {
    restoreBoxes.erase(window);
    Fullscreen::controller()->setFullscreenMode(window, Fullscreen::FSMODE_MAXIMIZED);
  } else {
    restoreBoxes.try_emplace(window, before);
    Fullscreen::controller()->setFullscreenMode(window, Fullscreen::FSMODE_NONE);
    const auto reserved = window->getFullWindowReservedArea();
    const CBox clientBox{box.pos() + reserved.topLeft, box.size() - reserved.topLeft - reserved.bottomRight};
    g_layoutManager->setTargetGeom(clientBox, window->layoutTarget());
  }
}
} // namespace

void omarchyFloatingSnapReset() {
  hidePreview();
  dragged.reset();
}

bool omarchyFloatingRestoreSnap(PHLWINDOW window) {
  const auto found = restoreBoxes.find(window);
  if (found == restoreBoxes.end())
    return false;
  const auto box = found->second;
  restoreBoxes.erase(found);
  g_layoutManager->setTargetGeom(box, window->layoutTarget());
  return true;
}

void omarchyFloatingSnapInit() {
  listeners.emplace_back(Event::bus()->m_events.input.mouse.move.listen([](Vector2D cursor, Event::SCallbackInfo &) { updatePreview(cursor); }));
  listeners.emplace_back(Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent event, Event::SCallbackInfo &) { release(event); }));
  listeners.emplace_back(Event::bus()->m_events.window.close.listen([](PHLWINDOW window) {
    restoreBoxes.erase(window);
    if (dragged == window)
      omarchyFloatingSnapReset();
  }));
}

void omarchyFloatingSnapExit() {
  omarchyFloatingSnapReset();
  listeners.clear();
  restoreBoxes.clear();
}
