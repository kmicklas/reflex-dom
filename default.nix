haskellPackages: let
  pkgs = haskellPackages.callPackage ({ pkgs }: pkgs) {};
  inherit (pkgs) stdenv;
  haskellLib = pkgs.haskell.lib;
in {
  reflex-dom-core = haskellPackages.callPackage
    ({ temporary, jsaddle-warp, process, chrome-test-utils, fontconfig, chromium, iproute }: let
      inherit (haskellPackages) ghc;
      noGcTest = stdenv.hostPlatform.system != "x86_64-linux"
              || stdenv.hostPlatform != stdenv.buildPlatform
              || (ghc.isGhcjs or false);
    in haskellLib.overrideCabal
      (haskellPackages.callCabal2nix "reflex-dom-core" ./reflex-dom-core { })
      (drv: {
        #TODO: Get hlint working for cross-compilation
        doCheck = stdenv.hostPlatform == stdenv.buildPlatform && !(ghc.isGhcjs or false);

        # The headless browser run as part of the tests will exit without this
        preBuild = ''
          export HOME="$PWD"
        '';

        # Show some output while running tests, so we might notice what's wrong
        testTarget = "--show-details=streaming";
      } // stdenv.lib.optionalAttrs (!noGcTest) {
        # The headless browser run as part of gc tests would hang/crash without this
        preCheck = ''
          export FONTCONFIG_PATH=${fontconfig.out}/etc/fonts
        '';
        testHaskellDepends = (drv.testHaskellDepends or []) ++ [
          temporary
          jsaddle-warp
          process
          chrome-test-utils
        ];
        testSystemDepends = (drv.testSystemDepends or []) ++ [ chromium iproute ];
      }))
    {};
  reflex-dom = haskellLib.overrideCabal
    (haskellPackages.callCabal2nix "reflex-dom" ./reflex-dom { })
    (drv:{
      configureFlags = (drv.configureFlags or [])
        ++ stdenv.lib.optional (stdenv.hostPlatform.libc == "bionic") "-fandroid";
    });
  chrome-test-utils = haskellPackages.callCabal2nix "chrome-test-utils" ./chrome-test-utils {};
}
