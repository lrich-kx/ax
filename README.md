# AX Module

The KDB-X AX module exposes components from the [AxLibraries](https://code.kx.com/developer/libraries/#q-libraries) using the modules framework. The current components that have been ported across are:

- [Grammar of Graphics](https://code.kx.com/developer/ggplot/) (ggplot) 
- [qDoc](https://code.kx.com/developer/libraries/#qdoc)
- [qDoc's parser](docs/qdocparser.md) (qdocparser), which qDoc uses to read q source


## Prerequisites

The KX Fusionx PCRE2 and Skia modules are required dependencies and need to be loaded via
```q
use`kx.fusion:pcre2
use`kx.skia
```
Respective installation instructions:
* [PCRE2](https://github.com/KxSystems/fusionx/blob/main/README.md)
* [Skia](https://github.com/KxSystems/qskia/blob/main/README.md)

## Build Instructions

The AX module contains a bitwise operations submodule (`qbitops`) which has a compilation step. 

:point_right: [`Build guide`](docs/build.md)

## Installation Documentation

:point_right: [`Install guide`](docs/install.md)

## API Documentation

The APIs match the AxLibraries APIs, with the benefit of being loadable to any namespace.

```q
([qp;gg;qd;qdp]):use`kx.ax;     // all components
([qd]):use`kx.ax.qdoc;          // or more granularly 
([qp;gg]):use`kx.ax.graphics;
qdp:use`kx.ax.qdocparser;
```

Simply replace `.qp`, `.gg` and `.qd` with `qp`, `gg` and `qd` respectively when referencing the AxLibraries API specifications (or the namespace you have chosen to assign the components to).

:point_right: [GGPlot](https://code.kx.com/analyst/libraries/grammar-of-graphics/)
:point_right: [qDoc](https://code.kx.com/developer/libraries/documentation-generator/)

### qDoc's parser

`kx.ax.qdocparser` reads the qdoc comments in q source into items and their tags: the parse qDoc's
`qd.doc` documents from. It is plain q, with no dependencies, so it loads on its own without PCRE2 or
Skia, for a tool that needs a q codebase's qdoc but not its rendered documentation.

```q
qdp:use`kx.ax.qdocparser;          // the parser alone
([qdp]):use`kx.ax;                 // or with the other components
it:qdp.items[()!(); `:src]         // every item under src, with its tags
```

It exports `getFiles`, `items`, `files`, `docItems` and `parameters`.

:point_right: [qdocparser API](docs/qdocparser.md)

## Notice

Copyright (c) 2026 KX Systems, Inc.

Licensed under the Apache License, Version 2.0.
