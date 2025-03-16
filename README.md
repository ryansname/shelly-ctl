## Shelly-ctl

Centralised shelly config management.

### Dependencies
- Option 1: [Zig 0.14](https://ziglang.org/download/)
- Option 2: [nix-shell](https://nixos.org/download/#)

### Running
`zig build run -- <ip> [ip...]`

Shelly-ctl will read a file called `config.zon` in the current working directory and
send the configured commands to any shelly it finds.

Currently configuration can be targetted using Shelly device generation, or MAC address.

#### Running on a range of IP
> [!WARNING]  
> Currently the TCP timeout is quite large, so this may take some time
> https://github.com/ziglang/zig/issues/19029

`zig build run -- 192.168.1.{0..255}`

### Config
The config file is dominated by sets of {service, payloads}.

Documentation
- [Gen 1](https://shelly-api-docs.shelly.cloud/gen1/#common-http-api)
  - Service is the URL path, eg. `/settings`
  - Payload is `<parameter>=<value>`, eg. `ap_roaming_enabled=true`

- [Gen 2 & 3](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/Introduction)
  - Service is the RPC method, eg. `Sys.SetConfig`
  - Payload is `<flattened json path>=<value>`, eg. `config.device.name=Shelly 2`

Below is a more complete example which sets coiot for gen 1 devices, enables eco mode and disables shelly cloud.
```
.{
    .byGen = .{
        .gen1 = .{
            .{
                .service = "/settings",
                .payloads = .{
                    "eco_mode_enabled=true",
                    "coiot_enable=true",
                    "coiot_peer=192.168.1.5:5683",
                },
            },
            .{
                .service = "/settings/cloud",
                .payloads = .{"enabled=false"},
            },
        },
        .gen2 = .{
            .{
                .service = "Sys.SetConfig",
                .payloads = .{"config.device.eco_mode=true"},
            },
            .{
                .service = "Cloud.SetConfig",
                .payloads = .{"config.enable=false"},
            },
        },
    },
    .byMac = .{
        .{
            .mac = "AABBCCDDEEFF",
            .name = "Lights",
            .configs = .{
                .{ .service = "/settings/relay/0", .payloads = .{"name=Kitchen"} },
                .{ .service = "/settings/relay/1", .payloads = .{"name=Dining"} },
            },
        },
        .{
            .mac = "FFEEDDCCBBAA",
            .name = "Pump",
            .configs = .{
                .{ .service = "Switch.SetConfig", .payloads = .{ "id=0&config.name=Mower Charger", "id=0&config.initial_state=on" } },
            },
        },
    },
}
```
