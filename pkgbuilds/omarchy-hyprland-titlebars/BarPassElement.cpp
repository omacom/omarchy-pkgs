#include "BarPassElement.hpp"
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include "barDeco.hpp"

using namespace Render::GL;

COmarchyFloatingBarPassElement::COmarchyFloatingBarPassElement(const COmarchyFloatingBarPassElement::SBarData &data_) : data(data_) { ; }

std::vector<UP<IPassElement>> COmarchyFloatingBarPassElement::draw() {
  data.deco->renderPass(g_pHyprRenderer->m_renderData.pMonitor.lock(), data.a);
  return {};
}

bool COmarchyFloatingBarPassElement::needsLiveBlur() {
  static auto PENABLEBLURGLOBAL = CConfigValue<Config::BOOL>("decoration:blur:enabled");

  CHyprColor color = data.deco->m_bForcedBarColor.value_or(CHyprColor{static_cast<uint64_t>(g_pOmarchyFloatingGlobalState->config.barColor->value())});
  color.a *= data.a;
  const bool SHOULDBLUR = g_pOmarchyFloatingGlobalState->config.barBlur->value() && *PENABLEBLURGLOBAL && color.a < 1.F;

  return SHOULDBLUR;
}

std::optional<CBox> COmarchyFloatingBarPassElement::boundingBox() {
  // Temporary fix: expand the bar bb a bit, otherwise occlusion gets too aggressive.
  return data.deco->assignedBoxGlobal().translate(-g_pHyprRenderer->m_renderData.pMonitor->m_position).expand(10);
}

bool COmarchyFloatingBarPassElement::needsPrecomputeBlur() { return false; }
