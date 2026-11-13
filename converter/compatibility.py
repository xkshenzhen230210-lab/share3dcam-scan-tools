"""Opt-in scheduling for the converter only; never changes SU or system policy."""
import ctypes as C
import os
import struct


def choose_mask(allowed,records):
    candidates=[(efficiency,logical) for group,logical,efficiency,flags in records
                if group==0 and allowed&(1<<logical) and not (flags&2 and not flags&4)]
    if not candidates:return allowed&-allowed
    classes={efficiency for efficiency,_ in candidates}
    if len(classes)>1:
        efficient=min(classes)
        return sum(1<<logical for efficiency,logical in candidates if efficiency==efficient)
    return 1<<min(logical for _,logical in candidates)


def enable_compatible_cpu():
    if os.name!='nt':raise RuntimeError('后台兼容模式仅支持Windows')
    k=C.WinDLL('kernel32',use_last_error=True);v=C.c_void_p;u=C.c_ulong;p=C.POINTER
    k.GetCurrentProcess.restype=v
    k.GetProcessAffinityMask.argtypes=[v,p(C.c_size_t),p(C.c_size_t)]
    k.SetProcessAffinityMask.argtypes=[v,C.c_size_t]
    process=k.GetCurrentProcess();allowed=C.c_size_t();system=C.c_size_t()
    if not k.GetProcessAffinityMask(process,C.byref(allowed),C.byref(system)):raise C.WinError(C.get_last_error())
    records=[]
    if hasattr(k,'GetSystemCpuSetInformation'):
        f=k.GetSystemCpuSetInformation;f.argtypes=[v,u,p(u),v,u];size=u()
        f(None,0,C.byref(size),process,0)
        if 0<size.value<1_048_576:
            buffer=C.create_string_buffer(size.value)
            if f(buffer,len(buffer),C.byref(size),process,0):
                raw=buffer.raw;offset=0
                while offset+8<=size.value:
                    length,kind=struct.unpack_from('<II',raw,offset)
                    if length<8 or offset+length>size.value:raise ValueError('CPU集合信息不完整')
                    if kind==0 and length>=20:
                        group=struct.unpack_from('<H',raw,offset+12)[0]
                        records.append((group,raw[offset+14],raw[offset+18],raw[offset+19]))
                    offset+=length
    mask=choose_mask(allowed.value,records)
    if not mask or not k.SetProcessAffinityMask(process,mask):raise C.WinError(C.get_last_error())
    return {'mode':'compatible','cpu_mask':mask,'previous_mask':allowed.value,
            'scope':'converter_process_only','logical_processors':mask.bit_count()}
