# Contributing

Do not add application-specific integrations when a capability can be discovered generically.

RIGHTCLICK asks macOS which capabilities apply to an object. A new app should show up because it publishes Services, sharing services, or Action Extension metadata, not because someone added its bundle id to this repository.

New capability-family support should be generic: one discovery path, one invocation path, and the same safety rules for every provider in that family.

Action Extensions are discovered and are not generically executable. Do not call private `NSExtension` methods from the product to pretend otherwise.

RIGHTCLICK is licensed under Apache-2.0. See `LICENSE`.
