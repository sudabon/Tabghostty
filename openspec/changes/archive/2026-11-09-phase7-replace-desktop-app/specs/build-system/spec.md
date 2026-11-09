# Spec Delta

## ADDED Requirements

### Requirement: Install command

The repository SHALL provide `make install`, which builds the app bundle, quits a running Tabghostty if there is one, and replaces `/Applications/Tabghostty.app` with the new bundle. It SHALL NOT stop the daemon or any session. After installing, it SHALL print the steps for restarting the daemon so that the newly bundled daemon is used.

#### Scenario: Upgrade while running

- **WHEN** Tabghostty is running with open sessions and the developer runs `make install`
- **THEN** Tabghostty quits, `/Applications/Tabghostty.app` is replaced, the sessions keep running in the daemon, and the daemon restart steps are printed

#### Scenario: First install

- **WHEN** `/Applications/Tabghostty.app` does not exist
- **THEN** `make install` copies the new bundle there
