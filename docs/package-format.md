# AtlasOS Ship Package Format

AtlasOS Ship releases are described by a manifest.

Files belong to one of three classes:

## system

Files owned by AtlasOS itself.

The installer may install, update, verify, repair, and replace these files upon installation.

## persistent

Machine-specific or user-specific data.

Normal installs and updates don't change these files.

Examples include configuration, pairing data, calibration, destinations, computer IDs, and radio settings.

## generated

Files created by AtlasOS while running.

They are not part of the release package and should not be verified against release hashes.