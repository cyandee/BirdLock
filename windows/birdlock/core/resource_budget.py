"""Conservative memory budgets for parallel image work, without extra dependencies."""
import os
import ctypes


def physical_memory():
    if os.name=='nt':
        class Status(ctypes.Structure):
            _fields_=[('length',ctypes.c_ulong),('load',ctypes.c_ulong)]+[(name,ctypes.c_ulonglong) for name in ('total','available','page','freepage','virtual','freevirtual','extended')]
        status=Status();status.length=ctypes.sizeof(status)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):return status.total
    try:return os.sysconf('SC_PHYS_PAGES')*os.sysconf('SC_PAGE_SIZE')
    except (ValueError,OSError,AttributeError):return 8<<30


def workers(bytes_per_task=96<<20,maximum=16,cpu=None,memory=None):
    budget=max(128<<20,min(1536<<20,(physical_memory() if memory is None else memory)//12))
    return max(1,min(maximum,max(1,((os.cpu_count() or 1) if cpu is None else (cpu or 1))-2),budget//max(1,bytes_per_task)))
