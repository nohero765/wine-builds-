# wine-builds
the wine that will be used for the TruckersMP launcher.

> [!NOTE]
> Still being worked on. A lot of things will be changed. 

> [!WARNING] 
>Known issues as of 9/7/2026                                                                
>Telemetry server fails to run under this wine due to wine mono version having bug with networking the telemetry server uses upgrading or downgrading wine mono will fix it              
>Alot of GStreamer warnings in the log may impact the initial startup of Steam for the first time.

## Credits

This project builds on [Wine](https://www.winehq.org) (LGPL-2.1)
and includes Steam compatibility patches adapted from CodeWeavers'
CrossOver source (LGPL-2.1+). See [NOTICE](./NOTICE) for full
attribution.
