{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  e = lib.escapeShellArg;
  cfg = config.services.declarative-jellyfin;
  genhash = import ./pbkdf2-sha512.nix { inherit pkgs; };
  djLib = import ../lib { nixpkgs = pkgs; };
  toXml' = djLib.toXMLGeneric;
  toPascalCase = djLib.toPascalCase;
  isStrList = x: all (x: isString x) x;
  prepass =
    x:
    if (isAttrs x) then
      if !(hasAttr "tag" x) then
        attrsets.mapAttrsToList (tag: value: {
          inherit tag;
          content = prepass value;
        }) x
      else if (hasAttr "content" x) then
        {
          tag = x.tag;
          content = prepass x.content;
        }
      else
        x
    else if (isList x) then
      if (isStrList x) then
        (map (content: {
          tag = "string";
          inherit content;
        }) x)
      else
        map prepass x
    else
      x;

  toXml =
    tag: x:
    (toXml' {
      inherit tag;
      attrib = {
        "xmlns:xsi" = "http://www.w3.org/2001/XMLSchema-instance";
        "xmlns:xsd" = "http://www.w3.org/2001/XMLSchema";
      };
      content = prepass x;
    });
  jellyfinConfigFiles = {
    "network.xml" = {
      name = "NetworkConfiguration";
      content = toPascalCase.fromAttrsRecursive cfg.network;
    };
    "encoding.xml" = {
      name = "EncodingOptions";
      content = toPascalCase.fromAttrsRecursive cfg.encoding;
    };
    "system.xml" = {
      name = "ServerConfiguration";
      content = toPascalCase.fromAttrsRecursive cfg.system;
    };
    "branding.xml" = {
      name = "BrandingOptions";
      content = toPascalCase.fromAttrsRecursive cfg.branding;
    };
  };

  # See: https://github.com/jellyfin/jellyfin/blob/master/src/Jellyfin.Database/Jellyfin.Database.Implementations/Enums/PermissionKind.cs
  permissionKindToDBInteger = {
    isAdministrator = 0;
    isHidden = 1;
    isDisabled = 2;
    enableSharedDeviceControl = 3;
    enableRemoteAccess = 4;
    enableLiveTvManagement = 5;
    enableLiveTvAccess = 6;
    enableMediaPlayback = 7;
    enableAudioPlaybackTranscoding = 8;
    enableVideoPlaybackTranscoding = 9;
    enableContentDeletion = 10;
    enableContentDownloading = 11;
    enableSyncTranscoding = 12;
    enableMediaConversion = 13;
    enableAllDevices = 14;
    enableAllChannels = 15;
    enableAllFolders = 16;
    enablePublicSharing = 17;
    enableRemoteControlOfOtherUsers = 18;
    enablePlaybackRemuxing = 19;
    forceRemoteSourceTranscoding = 20;
    enableCollectionManagement = 21;
    enableSubtitleManagement = 22;
    enableLyricManagement = 23;
  };
  # See: https://github.com/jellyfin/jellyfin/blob/master/src/Jellyfin.Database/Jellyfin.Database.Implementations/Enums/PreferenceKind.cs
  preferenceKindToDBInteger = {
    enabledFolders = 5;
  };
  subtitleModes = {
    default = 0;
    always = 1;
    onlyForce = 2;
    none = 3;
    smart = 4;
  };
  dbname = "jellyfin.db";
  nonDBOptions = [
    "noPassword"
    "hashedPasswordFile"
    "hashedPassword"
    "mutable"
    "permissions"
    "preferences"
    "_module"
  ];
  options = map (camelcase: toPascalCase.fromString camelcase) (
    lib.attrsets.mapAttrsToList (key: value: "${key}") (
      (builtins.removeAttrs (
        (import ./options/users.nix { inherit lib; })
        .options.services.declarative-jellyfin.users.type.getSubOptions
        [ ]
      ) nonDBOptions)
      // {
        username = null;
      }
    )
  );

  sqliteFormat =
    key: value:
    if
      (isBool value) # bool -> 1 or 0
    then
      if value then "1" else "0"
    else if
      (isNull value) # null -> NULL
    then
      "NULL"
    else if
      (key == "subtitleMode") # subtitleMode -> 0 | 1 | 2 | 3 | 4
    then
      subtitleModes.${value}
    else if (isString value) then
      "'${value}'"
    else
      value;
  sqliteFormatAttrs = attrset: builtins.mapAttrs (name: value: sqliteFormat name value) attrset;

  # This function replicates the LibraryManager.GetNewItemId() from the jellyfin source code.
  # It's used to generate the DB id used for referenceing specific folders/libraries (CollectionFolder)
  # The id of a CollectionFolder (library) is: The Folder class' fullname concattenated
  # with the path of to the library relative from the "virtual" jellyfin root with \ for path seperator
  # This generates a key like MediaBrowser.Controller.Entities.CollectionFolderroot\default\<library name>.
  # This gets converted to UTF-16LE and the md5 hash of that gets used as a GUID.
  # Don't ask me why they do it like this 💀
  genfolderuuid =
    pkgs.writeShellScriptBin "genfolderuuid"
      # bash
      ''
        key="root\\default\\$1"
        type="MediaBrowser.Controller.Entities.CollectionFolder"

        # Concatenate type.FullName + key
        input="''${type}''${key}"

        # Convert to UTF-16LE and hash with MD5
        md5hex="$(printf "%s" "$input" | ${pkgs.iconv}/bin/iconv -f UTF-8 -t UTF-16LE | md5sum | ${pkgs.gawk}/bin/awk '{print $1}')"

        # Format as GUID with .NET byte order (little-endian for first 3 fields)
        a="''${md5hex:6:2}''${md5hex:4:2}''${md5hex:2:2}''${md5hex:0:2}"
        b="''${md5hex:10:2}''${md5hex:8:2}"
        c="''${md5hex:14:2}''${md5hex:12:2}"
        d="''${md5hex:16:4}"
        e="''${md5hex:20:12}"

        guid="''${a}-''${b}-''${c}-''${d:0:4}-''${d:4:8}''${e}"

        # Lowercase to match .NET format
        echo "$(echo $guid | tr '[:upper:]' '[:lower:]')"
      '';

  optionsNoId = lib.lists.remove "Id" (lib.lists.remove "InternalId" options);
  genUser =
    index: username: userOpts:
    let
      mutatedUser = builtins.removeAttrs (
        userOpts
        // {
          inherit username;
          id =
            if !(isNull userOpts.id) then
              userOpts.id
            else
              "$(${pkgs.libuuid}/bin/uuidgen | ${pkgs.coreutils}/bin/tr '[:lower:]' '[:upper:]')";
          internalId =
            if !(isNull userOpts.internalId) then
              userOpts.internalId
            else
              "$((maxIndex+${toString (index + 1)}))";
          password =
            if userOpts.noPassword then
              null
            else if !(isNull userOpts.hashedPasswordFile) then
              "$(<${e userOpts.hashedPasswordFile})"
            else if !(isNull userOpts.hashedPassword) then
              ''"${e userOpts.hashedPassword}"''
            else
              "$(${genhash}/bin/genhash -k ${e userOpts.password} -i 210000 -l 128 -u)";
        }
      ) nonDBOptions;
      userWithNoId = removeAttrs mutatedUser [
        "id"
        "internalId"
      ];
    in
    # bash
    ''
      userExists="$(${sq} "SELECT 1 FROM Users WHERE Username = '${mutatedUser.username}'")"
      userId="${mutatedUser.id}"
      if [ -n "$userExists" ]; then
        # If the user already exists, we must update the user id to match the id in the DB,
        # rather than the randomly generated one
        userId="$(${sq} "SELECT Id FROM Users WHERE Username = '${mutatedUser.username}'")"
      fi
      echo "User id for ${mutatedUser.username} is: $userId"

      # If the user is mutable, only insert the user if it doesn't already exist, otherwise just overwrite
      if [ ${
        if (userOpts.mutable) then
          ''-z "$userExists"'' # user doesn't exist
        else
          "-n \"true\""
      } ]; then
        # password hash looks like substitution
        # shellcheck disable=SC2016
        sql="INSERT INTO Users (${concatStringsSep "," optionsNoId}, InternalId, Id) VALUES(${concatStringsSep "," (map toString (attrValues (sqliteFormatAttrs userWithNoId)))},$((maxIndex+${toString (index + 1)})), '$userId')"
        # User already exists - don't insert a new Id, just re-use the one already present,
        # so any foreign key relations don't fail because of overwriting with newly generated ID.
        if [ -n "$userExists" ]; then
          echo "Excluding insertion of Id/InternalId, since user already exists in DB"
          # password hash looks like substitution
          # shellcheck disable=SC2016
          sql="UPDATE Users SET ${
            concatStringsSep "," (
              map (
                {
                  fst,
                  snd,
                }:
                # bash
                ''${fst} = ${toString (sqliteFormat fst snd)}''
              ) (lib.lists.zipLists optionsNoId (attrValues userWithNoId))
            )
          } WHERE Username = '${mutatedUser.username}'"
        fi
        printf "%s;\n" "$sql" >> "$dbcmds"

        # Handle admin user preferences
        ${lib.optionalString (userOpts.preferences.enabledLibraries != [ ])
          # bash
          ''
            echo "REPLACE INTO Preferences(Kind, RowVersion, UserId, Value) VALUES(${toString preferenceKindToDBInteger.enabledFolders}, 0, '$userId',
            '${
              concatStringsSep "," (
                map (
                  enabledLib: "$(${genfolderuuid}/bin/genfolderuuid ${e enabledLib})"
                ) userOpts.preferences.enabledLibraries
              )
            }');" >> "$dbcmds"
          ''
        }

        # Handle user permissions
        ${concatStringsSep "\n" (
          lib.attrsets.mapAttrsToList (
            permission: enabled:
            # bash
            ''
              sql="REPLACE INTO Permissions (Kind, Value, UserId, Permission_Permissions_Guid, RowVersion) VALUES(${
                toString permissionKindToDBInteger.${permission}
              }, ${if enabled then "1" else "0"}, '$userId', NULL, 0);"
              echo "$sql" >> "$dbcmds"
            '') userOpts.permissions
        )}
      fi
    '';

  prepassedLibraries = builtins.mapAttrs (
    name: value:
    toPascalCase.fromAttrsRecursive (
      value
      // {
        typeOptions = mapAttrsToList (name: value: {
          typeOptions =
            value
            // (with value; {
              type = name;
              metadataFetcherOrder = metadataFetchers;
              imageFetcherOrder = imageFetchers;
            });
        }) cfg.libraries."${name}".typeOptions;
        pathInfos = builtins.map (x: { MediaPathInfo.Path = x; }) value.pathInfos;
      }
    )
  ) cfg.libraries;

  dbPath = "${config.services.jellyfin.dataDir}/data/${dbname}";
  sq = ''${pkgs.sqlite}/bin/sqlite3 ${lib.escapeShellArg dbPath} --'';
  dbcmdfile = "dbcommands.sql";
  configDerivations = mapAttrs (
    file: cfg: pkgs.writeText file (toXml cfg.name cfg.content)
  ) jellyfinConfigFiles;
  jellyfin-exec = "${getExe config.services.jellyfin.package} --datadir '${config.services.jellyfin.dataDir}' --configdir '${config.services.jellyfin.configDir}' --cachedir '${config.services.jellyfin.cacheDir}' --logdir '${config.services.jellyfin.logDir}'";
in
{
  config = mkIf cfg.enable {
    services.jellyfin = {
      enable = true;
      inherit (cfg)
        user
        group
        dataDir
        configDir
        cacheDir
        logDir
        ;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      cfg.network.publicHttpPort
      cfg.network.publicHttpsPort
    ];
    systemd.services.jellyfin.preStart = ''
      set -euo pipefail
      # u=rwx
      # g=r-x
      # o=---
      umask 027

      # Setup directories
      declare -a dirs=(
        "${config.services.jellyfin.configDir}"
        "${config.services.jellyfin.logDir}"
        "${config.services.jellyfin.cacheDir}"
        "${config.services.jellyfin.dataDir}/metadata"
        "${config.services.jellyfin.dataDir}/playlists"
        "${config.services.jellyfin.dataDir}/wwwroot"
        "${config.services.jellyfin.dataDir}/plugins/configurations"
      )
      mkdir -p -- "''${dirs[@]}"

      function handle_error() {
        echo "An ERROR occured during jellyfin-init!"
      }

      trap handle_error ERR

      dbcmds="$(mktemp -d)/${dbcmdfile}"
      install -Dm 774 /dev/null "$dbcmds"
      trap 'rm -rf -- "$dbcmds"' exit
      echo "BEGIN TRANSACTION;" > "$dbcmds"


      # Install each config
      ${concatStringsSep "\n" (
        mapAttrsToList (
          file: path: ''install -Dm 640 "${path}" "${config.services.jellyfin.configDir}/${file}"''
        ) configDerivations
      )}

      ${lib.optionalString cfg.system.isStartupWizardCompleted
        # bash
        ''
          # We need to generate a valid migrations.xml file if it's a first run and
          # `services.declarative-jellyfin.system.IsStartupWizardCompleted=true`
          # otherwise jellyfin will try and run deprecated/old migrations, see:
          # https://github.com/jellyfin/jellyfin/issues/12254
          if [[ ! -f "${config.services.jellyfin.configDir}/migrations.xml" ]] && [[ ! -f "${config.services.jellyfin.configDir}/migrations.xml.backup" ]]; then
            echo "First time run and no migrations.xml. We run jellyfin once to generate it..."
            echo "Starting jellyfin with IsStartupWizardCompleted = false"
            ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L -u "//IsStartupWizardCompleted" -v "false" "${config.services.jellyfin.configDir}/system.xml"
            ${jellyfin-exec} & disown
            echo "Waiting for jellyfin to generate migrations.xml"
            until [ -f "${config.services.jellyfin.configDir}/migrations.xml" ]
            do
              sleep 1
            done
            sleep 5
            echo "migrations.xml generated! Restarting jellyfin..."
            echo "migrations.xml:"
            cat "${config.services.jellyfin.configDir}/migrations.xml"
            ${pkgs.procps}/bin/pkill -15 -f ${config.services.jellyfin.package}
            echo "Waiting for jellyfin to shut down properly"
            while ${pkgs.ps}/bin/ps axg | ${pkgs.gnugrep}/bin/grep -vw grep | ${pkgs.gnugrep}/bin/grep -w ${config.services.jellyfin.package} > /dev/null; do sleep 1 && printf "."; done
            echo "Jellyfin terminated. Resetting with IsStartupWizardCompleted set to true"
            ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L -u "//IsStartupWizardCompleted" -v "true" "${config.services.jellyfin.configDir}/system.xml"
          fi
        ''
      }

      # Make sure there is a database
      if [ ! -e "${config.services.jellyfin.dataDir}/data/${dbname}" ]; then
        echo "No DB found. First time run detected. Launching jellyfin once to generate initial config + DB..."
        ${jellyfin-exec} & disown

        echo "Waiting for jellyfin finish startup"
        until [ -f ${lib.escapeShellArg dbPath} ]
        do
          sleep 1
        done
        sleep 5
        echo "Initial jellyfin setup done"
        ${pkgs.procps}/bin/pkill -15 -f ${config.services.jellyfin.package}
        echo "Waiting for jellyfin to shut down properly"
        while ${pkgs.ps}/bin/ps axg | ${pkgs.gnugrep}/bin/grep -vw grep | ${pkgs.gnugrep}/bin/grep -w ${config.services.jellyfin.package} > /dev/null; do sleep 1 && printf "."; done
        cat "${config.services.jellyfin.configDir}/migrations.xml"
        echo "Jellyfin terminated"
      fi

      # Rotating backups
      ${lib.optionalString cfg.backups
        # bash
        ''
          backupDir=${e cfg.backupDir}
          # Make sure backupDir exists
          mkdir -p -- "$backupDir"
          backupName="$backupDir/backup_$(date +%Y%m%d%H%M%S%N).tar.gz"

          install -Dm 775 /dev/null "$backupName"
          echo "Creating backup: $backupName"
          ${pkgs.gnutar}/bin/tar -c --exclude "${removePrefix "/" cfg.backupDir}" -C / ${removePrefix "/" config.services.jellyfin.logDir} -C / ${removePrefix "/" config.services.jellyfin.dataDir} -C / ${removePrefix "/" config.services.jellyfin.configDir} -C / ${removePrefix "/" config.services.jellyfin.cacheDir} -f - | ${pkgs.pigz}/bin/pigz > "$backupName"

          # Rotate backups
          declare -a backups
          mapfile -d "" -t backups < <(find "$backupDir" -type f -print0 | sort -z)
          declare -i num_backups num_backups_to_remove
          num_backups=''${#backups[@]}
          num_backups_to_remove=$((num_backups - ${toString cfg.backupCount}))

          if (( num_backups_to_remove > 0 )); then
            declare -a old_backups
            old_backups=("''${backups[@]:0:$num_backups_to_remove}")
            for old_backup in "''${old_backups[@]}"; do
              rm "$old_backup"
              echo "Purged backup: $old_backup"
            done
          fi
        ''
      }

      # Server id
      ${lib.optionalString (!isNull cfg.serverId) # bash
        ''
          install -Dm 740 /dev/null "${config.services.jellyfin.dataDir}/data/device.txt"
          printf "%s" ${lib.escapeShellArg cfg.serverId} > "${config.services.jellyfin.dataDir}/data/device.txt"
        ''
      }

      maxIndex="$(${sq} 'SELECT InternalId FROM Users ORDER BY InternalId DESC LIMIT 1')"
      if [ -z "$maxIndex" ]; then
        maxIndex="1"
      fi
      echo "Max index: $maxIndex"

      # Generate each user
      ${concatStringsSep "\n" (
        map
          (
            {
              fst,
              snd,
            }:
            genUser fst snd cfg.users.${snd}
          )
          (
            lib.lists.zipLists (builtins.genList (x: x) (builtins.length (builtins.attrValues cfg.users))) (
              builtins.attrNames cfg.users
            )
          )
      )}

      # Handle libraries
      ${builtins.concatStringsSep "\n" (
        mapAttrsToList (
          name: value:
          let
            path = "${config.services.jellyfin.dataDir}/root/default/${name}";
          in
          # bash
          ''
            install -Dm 740 '${pkgs.writeText "options.xml" (toXml "LibraryOptions" value)}' "${path}/options.xml"
            touch "${path}/${value.ContentType}.collection"
            # Create .mblink files foreach path in library
            ${concatStringsSep "\n" (
              map (
                pathInfo:
                # bash
                ''
                  install -Dm 740 /dev/null "${config.services.jellyfin.dataDir}/root/default/${name}/${baseNameOf pathInfo.MediaPathInfo.Path}.mblink"
                  printf "%s" ${lib.escapeShellArg pathInfo.MediaPathInfo.Path} > "${config.services.jellyfin.dataDir}/root/default/${name}/${baseNameOf pathInfo.MediaPathInfo.Path}.mblink"
                '') value.PathInfos
            )}
          ''
        ) prepassedLibraries
      )}

      # API Keys
      ${concatStringsSep "\n" (
        mapAttrsToList (
          appName: value:
          # bash
          ''
            echo "REPLACE INTO ApiKeys (DateCreated, DateLastActivity, Name, AccessToken) VALUES(time(), time(), '${appName}', ${
              if !(isNull value.key) then "'${value.key}'" else "'$(cat \"${value.keyPath}\")'"
            });" >> "$dbcmds"
          '') cfg.apikeys
      )}

      # Commit SQL commands
      echo "COMMIT TRANSACTION;" >> "$dbcmds"
      echo "Executing SQL Commands:"
      cat "$dbcmds"
      ${pkgs.sqlite}/bin/sqlite3 "${config.services.jellyfin.dataDir}/data/${dbname}" < "$dbcmds"
    '';
    # systemd.services.jellyfin.serviceConfig.ExecStart =
    #   lib.mkForce "+${jellyfin-init}/bin/jellyfin-init";
  };
}
