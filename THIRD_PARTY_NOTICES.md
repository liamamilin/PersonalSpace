# Third-party notices

## Oil Find

`PersonalSpace/Library/NativeScan/BulkDirectoryReader.c` and its header adapt the bulk directory metadata decoder from Oil Find, commit `8f7b9db9e9785eb0a75746fa7f3c66fd47aae6c8`, `Sources/COilFind/coilfind.c` (`sift_read_dir`) and `include/coilfind.h`.

Source: https://github.com/oil-oil/oil-find/tree/8f7b9db9e9785eb0a75746fa7f3c66fd47aae6c8

The Swift directory traversal also follows its descriptor verification approach. PersonalSpace keeps its own database, authorization, read-only scope, package handling and history reconciliation. Changes include creation/subsecond timestamps, hidden flags, descriptor-relative traversal and fallback traversal for filesystems without bulk attributes.

MIT License

Copyright (c) 2026 Lin Zhihuang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

