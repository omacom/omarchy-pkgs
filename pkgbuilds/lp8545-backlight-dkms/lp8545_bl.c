// SPDX-License-Identifier: GPL-2.0-only
/*
 * lp8545_bl - backlight driver for the TI LP8545 on MacBookPro8,x
 *
 * The gmux backlight register is dead on this machine once the AMD GPU is
 * disabled: the LP8545 stays in PWM-input mode with its PWM input stuck high,
 * so the panel is pinned at 100%.  The LP8545 itself is alive on the i801
 * SMBus at 0x2c and supports direct I2C brightness control.
 *
 * This driver switches the chip to "brightness register" mode and registers a
 * normal /sys/class/backlight device, so brightnessctl / desktop sliders work.
 */

#include <linux/backlight.h>
#include <linux/dmi.h>
#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <linux/string.h>

#define LP8545_ADDR     0x2c
#define LP8545_REG_BRIGHTNESS   0x00
#define LP8545_REG_DEVICE_CTRL    0x01
#define LP8545_REG_ID     0x03

#define LP8545_ID     0xfc
#define LP8545_MAX_BRIGHTNESS   0xff

/* Device Control: BRT_MODE[2:1] = 10b (brightness register), BL_CTL = 1 */
#define LP8545_CTRL_I2C     0x05

struct lp8545_bl {
  struct i2c_client *client;
  struct backlight_device *bd;
  u8 saved_ctrl;
  u8 saved_brightness;
};

static struct lp8545_bl *lp8545_dev;

static int lp8545_write(struct lp8545_bl *priv, u8 reg, u8 value)
{
  int ret = i2c_smbus_write_byte_data(priv->client, reg, value);

  if (ret < 0)
    dev_err(&priv->client->dev,
      "failed to write reg 0x%02x: %d\n", reg, ret);
  return ret;
}

static int lp8545_read(struct lp8545_bl *priv, u8 reg)
{
  int ret = i2c_smbus_read_byte_data(priv->client, reg);

  if (ret < 0)
    dev_err(&priv->client->dev,
      "failed to read reg 0x%02x: %d\n", reg, ret);
  return ret;
}

static int lp8545_update_status(struct backlight_device *bd)
{
  struct lp8545_bl *priv = bl_get_data(bd);
  int brightness = backlight_get_brightness(bd);
  int ret;

  /*
   * Re-apply the mode on every update: if the chip is reset (resume,
   * SMC/gmux activity) it falls back to PWM-input mode and ignores the
   * brightness register.
   */
  ret = lp8545_write(priv, LP8545_REG_BRIGHTNESS, brightness);
  if (ret < 0)
    return ret;

  return lp8545_write(priv, LP8545_REG_DEVICE_CTRL, LP8545_CTRL_I2C);
}

static int lp8545_get_brightness(struct backlight_device *bd)
{
  struct lp8545_bl *priv = bl_get_data(bd);

  return lp8545_read(priv, LP8545_REG_BRIGHTNESS);
}

static const struct backlight_ops lp8545_bl_ops = {
  .options = BL_CORE_SUSPENDRESUME,
  .update_status = lp8545_update_status,
  .get_brightness = lp8545_get_brightness,
};

static int lp8545_match_i801(struct device *dev, void *data)
{
  struct i2c_adapter *adap = i2c_verify_adapter(dev);
  struct i2c_adapter **found = data;

  if (!adap || !strstr(adap->name, "SMBus I801"))
    return 0;
  *found = i2c_get_adapter(adap->nr);
  return *found != NULL;
}

static int __init lp8545_bl_init(void)
{
  struct i2c_adapter *adap = NULL;
  struct pci_dev *pdev = NULL;
  struct i2c_client *client;
  struct backlight_device *bd;
  struct backlight_properties props;
  struct lp8545_bl *priv;
  int id, ret, saved_ctrl, saved_brightness;
  int initial_brightness;

  /* Never take over a healthy dual-GPU Mac or an untested model. Firmware
   * must already have disabled/hidden the failed AMD GPU. */
  if (!dmi_match(DMI_SYS_VENDOR, "Apple Inc.") ||
      !dmi_match(DMI_PRODUCT_NAME, "MacBookPro8,2"))
    return -ENODEV;
  while ((pdev = pci_get_device(PCI_VENDOR_ID_ATI, PCI_ANY_ID, pdev))) {
    if ((pdev->class >> 16) == PCI_BASE_CLASS_DISPLAY) {
      pci_dev_put(pdev);
      return -ENODEV;
    }
  }

  i2c_for_each_dev(&adap, lp8545_match_i801);
  if (!adap) {
    pr_err("lp8545_bl: i801 SMBus adapter not found\n");
    return -ENODEV;
  }
  if (!i2c_check_functionality(adap, I2C_FUNC_SMBUS_BYTE_DATA)) {
    i2c_put_adapter(adap);
    return -EOPNOTSUPP;
  }

  client = i2c_new_dummy_device(adap, LP8545_ADDR);
  i2c_put_adapter(adap);
  if (IS_ERR(client)) {
    ret = PTR_ERR(client);
    pr_err("lp8545_bl: cannot create i2c client: %d\n", ret);
    return ret;
  }

  id = i2c_smbus_read_byte_data(client, LP8545_REG_ID);
  if (id < 0) {
    ret = id;
    pr_err("lp8545_bl: cannot read chip ID: %d\n", ret);
    goto err_client;
  }
  if (id != LP8545_ID) {
    ret = -ENODEV;
    pr_err("lp8545_bl: unexpected chip ID 0x%02x (expected 0x%02x)\n",
           id, LP8545_ID);
    goto err_client;
  }

  priv = kzalloc(sizeof(*priv), GFP_KERNEL);
  if (!priv) {
    ret = -ENOMEM;
    goto err_client;
  }
  priv->client = client;

  saved_ctrl = lp8545_read(priv, LP8545_REG_DEVICE_CTRL);
  if (saved_ctrl < 0) {
    ret = saved_ctrl;
    goto err_free;
  }
  saved_brightness = lp8545_read(priv, LP8545_REG_BRIGHTNESS);
  if (saved_brightness < 0) {
    ret = saved_brightness;
    goto err_free;
  }
  priv->saved_ctrl = saved_ctrl;
  priv->saved_brightness = saved_brightness;
  initial_brightness = (saved_ctrl & 0x06) == 0x04 ?
    saved_brightness : LP8545_MAX_BRIGHTNESS;

  /*
   * Load the brightness register with full brightness *before* switching
   * modes, so the panel does not flash to a stale value.
   */
  ret = lp8545_write(priv, LP8545_REG_BRIGHTNESS, initial_brightness);
  if (ret < 0)
    goto err_free;
  ret = lp8545_write(priv, LP8545_REG_DEVICE_CTRL, LP8545_CTRL_I2C);
  if (ret < 0)
    goto err_restore;

  memset(&props, 0, sizeof(props));
  props.type = BACKLIGHT_PLATFORM;
  props.max_brightness = LP8545_MAX_BRIGHTNESS;
  props.brightness = initial_brightness;

  bd = backlight_device_register("lp8545_backlight", &client->dev, priv,
               &lp8545_bl_ops, &props);
  if (IS_ERR(bd)) {
    ret = PTR_ERR(bd);
    pr_err("lp8545_bl: cannot register backlight: %d\n", ret);
    goto err_restore;
  }

  priv->bd = bd;
  ret = backlight_update_status(bd);
  if (ret < 0) {
    backlight_device_unregister(bd);
    goto err_restore;
  }
  lp8545_dev = priv;

  dev_info(&client->dev, "LP8545 backlight ready (I2C mode, max %d)\n",
     LP8545_MAX_BRIGHTNESS);
  return 0;

err_restore:
  lp8545_write(priv, LP8545_REG_BRIGHTNESS, priv->saved_brightness);
  lp8545_write(priv, LP8545_REG_DEVICE_CTRL, priv->saved_ctrl);
err_free:
  kfree(priv);
err_client:
  i2c_unregister_device(client);
  return ret;
}

static void __exit lp8545_bl_exit(void)
{
  struct lp8545_bl *priv = lp8545_dev;

  if (!priv)
    return;

  backlight_device_unregister(priv->bd);
  /* Put the chip back the way we found it. */
  lp8545_write(priv, LP8545_REG_BRIGHTNESS, priv->saved_brightness);
  lp8545_write(priv, LP8545_REG_DEVICE_CTRL, priv->saved_ctrl);
  i2c_unregister_device(priv->client);
  kfree(priv);
  lp8545_dev = NULL;
}

module_init(lp8545_bl_init);
module_exit(lp8545_bl_exit);

MODULE_AUTHOR("MarkPronkin <109197080+MarkPronkin@users.noreply.github.com>");
MODULE_DESCRIPTION("TI LP8545 I2C backlight for MacBookPro8,2 with disabled AMD GPU");
MODULE_SOFTDEP("pre: i2c_i801");
MODULE_LICENSE("GPL");
