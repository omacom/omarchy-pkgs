// Stand-in for Slack's closed-source native helpers, which ship no aarch64
// build. Slack's main bundle requires this module while booting, so a missing
// addon stops the window from ever opening. Every native call throws the same
// error the vendor wrapper uses for methods a platform lacks, and Slack's call
// sites already catch it and fall back.
const unavailable = () => {
  throw new Error('Method not implemented');
};

const namespace = new Proxy(
  {},
  {
    get: (_, key) =>
      typeof key === 'symbol' || key === 'then' ? undefined : unavailable,
  },
);

const constants = {
  AppRestartFlags: { NoCrash: 1, NoHang: 2, NoPatch: 4, NoReboot: 8 },
  WindowsNotifierState: {
    NotificationPlatformUnavailable: -2,
    Error: -1,
    Enabled: 0,
    DisabledForApplication: 1,
    DisabledForUser: 2,
    DisabledByGroupPolicy: 3,
    DisabledByManifest: 4,
  },
  StartupTaskState: {
    Error: -1,
    Disabled: 0,
    DisabledByUser: 1,
    Enabled: 2,
    DisabledByPolicy: 3,
    EnabledByPolicy: 4,
  },
  ActivationType: { Error: -1, StartupTask: 1020 },
};

module.exports = new Proxy(constants, {
  get: (target, key) => {
    if (key in target) return target[key];
    if (
      typeof key === 'symbol' ||
      key === '__esModule' ||
      key === 'default' ||
      key === 'then'
    ) {
      return undefined;
    }
    return namespace;
  },
});
