import argo.interaction
from argo.interaction import HasProtocolState
from . import exceptions

from typing import Any, List

class SAWCommand(argo.interaction.Command):
    def process_error(self, ae : argo.interaction.ArgoException) -> Exception:
        return exceptions.make_saw_exception(ae)

class CryptolLoadFile(SAWCommand):
    def __init__(self, connection : HasProtocolState, filename : str) -> None:
        super(CryptolLoadFile, self).__init__(
            'SAW/Cryptol/load file',
            {'file': filename},
            connection
        )

    def process_result(self, _res : Any) -> Any:
        return None

class CryptolLoadModule(SAWCommand):
    def __init__(self, connection : HasProtocolState, module_name : str) -> None:
        super(CryptolLoadModule, self).__init__(
            'SAW/Cryptol/load module',
            {'module': module_name},
            connection
        )

    def process_result(self, _res : Any) -> Any:
        return None

class LLVMLoadModule(SAWCommand):
    def __init__(self, connection : HasProtocolState,
                 name : str,
                 bitcode_file : str) -> None:
        super(LLVMLoadModule, self).__init__(
            'SAW/LLVM/load module',
            {'name': name, 'bitcode file': bitcode_file},
            connection
        )

    def process_result(self, _res : Any) -> Any:
        return None

class LLVMAssume(SAWCommand):
    def __init__(
            self,
            connection : HasProtocolState,
            module : str,
            function : str,
            setup : Any,
            lemma_name : str) -> None:
        params = {'module': module,
                  'function': function,
                  'contract': setup,
                  'lemma name': lemma_name}
        super(LLVMAssume, self).__init__('SAW/LLVM/assume', params, connection)

    def process_result(self, _res : Any) -> Any:
        return None

class LLVMVerify(SAWCommand):
    def __init__(
            self,
            connection : HasProtocolState,
            module : str,
            function : str,
            lemmas : List[str],
            check_sat : bool,
            setup : Any,
            script : str,
            lemma_name : str) -> None:
        params = {'module': module,
                  'function': function,
                  'lemmas': lemmas,
                  'check sat': check_sat,
                  'contract': setup,
                  'script': script,
                  'lemma name': lemma_name}
        super(LLVMVerify, self).__init__('SAW/LLVM/verify', params, connection)

    def process_result(self, _res : Any) -> Any:
        return None
