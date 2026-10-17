<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
 "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">

<policyconfig>
    <action id="com.1password.1Password.unlock">
      <description>Unlock 1Password</description>
      <message>Authenticate to unlock 1Password</message>
      <defaults>
        <allow_any>auth_self</allow_any>
        <allow_inactive>auth_self</allow_inactive>
        <allow_active>auth_self</allow_active>
      </defaults>
    </action>
    <action id="com.1password.1Password.authorizeCLI">
      <description>Authorize CLI</description>
      <message>1Password CLI is trying to access your 1Password account.</message>
      <defaults>
        <allow_any>auth_self</allow_any>
        <allow_inactive>auth_self</allow_inactive>
        <allow_active>auth_self</allow_active>
      </defaults>
      <annotate key="org.freedesktop.policykit.owner">${POLICY_OWNERS}</annotate>
    </action>
    <action id="com.1password.1Password.authorizeSshAgent">
      <description>Authorize SSH Agent</description>
      <message>1Password SSH Agent is trying to access your 1Password account.</message>
      <defaults>
        <allow_any>auth_self</allow_any>
        <allow_inactive>auth_self</allow_inactive>
        <allow_active>auth_self</allow_active>
      </defaults>
      <annotate key="org.freedesktop.policykit.owner">${POLICY_OWNERS}</annotate>
     </action>
</policyconfig>
