/**
 * Cross-language golden vectors for VAL-PATH-001.
 * Shared intent with OpenBurnBarLinuxPaths.swift and extension resolveOpenBurnBarDaemonRuntimePaths.
 * Swift unit coverage can import the same shapes once a Linux path XCTest lands.
 */
export type PathGolden = {
  name: string;
  env: Record<string, string | undefined>;
  home: string;
  expect: {
    supportDir: string;
    socketPath: string;
    authTokenPath: string;
    configDir: string;
  };
};

export const LINUX_PATH_GOLDENS: PathGolden[] = [
  {
    name: 'default-xdg-runtime',
    env: {
      XDG_DATA_HOME: '/home/alice/.local/share',
      XDG_CONFIG_HOME: '/home/alice/.config',
      XDG_RUNTIME_DIR: '/run/user/1000'
    },
    home: '/home/alice',
    expect: {
      supportDir: '/home/alice/.local/share/openburnbar',
      socketPath: '/run/user/1000/openburnbar/daemon.sock',
      authTokenPath: '/home/alice/.local/share/openburnbar/daemon-socket-auth-token',
      configDir: '/home/alice/.config/openburnbar'
    }
  },
  {
    name: 'custom-xdg-data',
    env: {
      XDG_DATA_HOME: '/var/lib/obb',
      XDG_RUNTIME_DIR: '/run/user/42'
    },
    home: '/home/bob',
    expect: {
      supportDir: '/var/lib/obb/openburnbar',
      socketPath: '/run/user/42/openburnbar/daemon.sock',
      authTokenPath: '/var/lib/obb/openburnbar/daemon-socket-auth-token',
      configDir: '/home/bob/.config/openburnbar'
    }
  },
  {
    name: 'support-override',
    env: {
      OPENBURNBAR_DAEMON_SUPPORT_DIR: '/srv/state',
      XDG_RUNTIME_DIR: '/run/user/1'
    },
    home: '/home/carol',
    expect: {
      supportDir: '/srv/state',
      socketPath: '/run/user/1/openburnbar/daemon.sock',
      authTokenPath: '/srv/state/daemon-socket-auth-token',
      configDir: '/home/carol/.config/openburnbar'
    }
  },
  {
    name: 'socket-override-wins',
    env: {
      OPENBURNBAR_SOCKET_PATH: '/tmp/custom.sock',
      XDG_RUNTIME_DIR: '/run/user/1',
      XDG_DATA_HOME: '/data'
    },
    home: '/home/dave',
    expect: {
      supportDir: '/data/openburnbar',
      socketPath: '/tmp/custom.sock',
      authTokenPath: '/data/openburnbar/daemon-socket-auth-token',
      configDir: '/home/dave/.config/openburnbar'
    }
  },
  {
    name: 'no-runtime-fallback-socket',
    env: {
      XDG_DATA_HOME: '/data'
    },
    home: '/home/erin',
    expect: {
      supportDir: '/data/openburnbar',
      socketPath: '/data/openburnbar/openburnbar-daemon.sock',
      authTokenPath: '/data/openburnbar/daemon-socket-auth-token',
      configDir: '/home/erin/.config/openburnbar'
    }
  }
];
