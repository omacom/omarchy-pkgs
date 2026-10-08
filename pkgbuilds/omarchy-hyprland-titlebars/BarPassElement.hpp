#pragma once
#include <hyprland/src/render/pass/PassElement.hpp>

class COmarchyFloatingHyprBar;

class COmarchyFloatingBarPassElement : public IPassElement {
public:
  struct SBarData {
    COmarchyFloatingHyprBar *deco = nullptr;
    float a = 1.F;
  };

  COmarchyFloatingBarPassElement(const SBarData &data_);
  virtual ~COmarchyFloatingBarPassElement() = default;

  virtual std::vector<UP<IPassElement>> draw() override;
  virtual bool needsLiveBlur() override;
  virtual bool needsPrecomputeBlur() override;
  virtual std::optional<CBox> boundingBox() override;

  virtual const char *passName() override { return "COmarchyFloatingBarPassElement"; }

  virtual ePassElementType type() override { return EK_CUSTOM; }

private:
  SBarData data;
};