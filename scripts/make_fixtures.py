"""Create synthetic M1 demo files. Never touches user documents or the app database."""
from pathlib import Path
import struct
import zlib

root = Path(__file__).resolve().parent.parent / 'fixtures' / 'M1'
a, b = root/'A', root/'B'
a.mkdir(parents=True, exist_ok=True)
b.mkdir(parents=True, exist_ok=True)
objects = [
    b'<< /Type /Catalog /Pages 2 0 R >>',
    b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 540] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
]
content = b'BT /F1 24 Tf 42 450 Td (PersonalSpace) Tj 0 -42 Td /F1 18 Tf (M1 - Order Sample) Tj 0 -42 Td /F1 12 Tf (Synthetic test document - no real transaction) Tj 0 -28 Td (Order: TEST-001) Tj 0 -24 Td (Item: Test device) Tj ET'
objects.append(b'<< /Length '+str(len(content)).encode()+b' >>\nstream\n'+content+b'\nendstream')
pdf = b'%PDF-1.4\n'
offsets = [0]
for i, obj in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
xref = len(pdf)
pdf += b'xref\n0 6\n0000000000 65535 f \n'
for offset in offsets[1:]: pdf += f'{offset:010d} 00000 n \n'.encode()
pdf += f'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
(a/'订单样例.pdf').write_bytes(pdf)
(b/'租赁合同.txt').write_text('PersonalSpace M1 合成测试资料\n\n租赁合同（演示样例）\n此文件不包含真实合同或个人信息。\n用于验证跨来源搜索、系统预览、打开与重启持久化。\n', encoding='utf-8')
def chunk(kind, data):
    return struct.pack('>I',len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data)&0xffffffff)
w,h = 480,320
raw=bytearray()
for y in range(h):
    raw.append(0)
    for x in range(w):
        if 95<x<385 and 55<y<235:
            rgb=(55,67,81) if x<106 or x>374 or y<66 or y>224 else (121,169,189)
        elif 215<x<265 and 235<=y<270 or 175<x<305 and 270<=y<282:
            rgb=(72,82,92)
        else: rgb=(231,235,238)
        raw.extend(rgb)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(bytes(raw)))+chunk(b'IEND',b'')
(b/'设备照片.png').write_bytes(png)
print(root)
