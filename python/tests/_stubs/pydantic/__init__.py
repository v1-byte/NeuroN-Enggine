# STUB: meniru BaseModel minimal (field wajib vs default, model_dump_json). Tanpa validasi tipe.
import json
def Field(default=..., **kwargs):
    return default

class BaseModel:
    def __init__(self, **data):
        names = []
        for klass in reversed(type(self).__mro__):
            names += [n for n in getattr(klass, "__annotations__", {}) if n not in names]
        for n in names:
            if n in data:
                setattr(self, n, data[n])
            elif hasattr(type(self), n):
                setattr(self, n, getattr(type(self), n))
            else:
                raise ValueError(f"field '{n}' wajib")
    def model_dump_json(self):
        return json.dumps({n: getattr(self, n) for n in type(self).__annotations__}, default=str)
