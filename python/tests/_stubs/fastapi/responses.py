class FileResponse:
    def __init__(self, path, **kw): self.path = path
class StreamingResponse:
    def __init__(self, content, **kw): self.content = content
