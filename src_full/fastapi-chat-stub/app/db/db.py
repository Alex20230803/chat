# db/db.py
from pathlib import Path
from .config import get_settings
from .engine import create_engine_from_settings

# ваши репозитории, оставляю как в проекте
from .core import Database
from .repositories.prompts import PromptsRepo
from .repositories.llms import LlmsRepo
from .repositories.pcaches import PcachesRepo
from .repositories.artifacts import ArtifactsRepo
from .repositories.user_docs import UserDocsRepo
from .repositories.agent_sub_kinds import AgentSubKindsRepo
from .repositories.chat_repo import ChatRepo

SETTINGS = get_settings()                 # <-- единственное чтение файла
ENGINE   = create_engine_from_settings(SETTINGS)

DB       = Database(ENGINE)
PROMPTS  = PromptsRepo(DB.engine)
LLMS     = LlmsRepo(DB.engine)
PCACHES  = PcachesRepo(DB.engine)
#ARTIFACTS = ArtifactsRepo(DB.engine)
USER_DOCS = UserDocsRepo(DB.engine)
AGENT_SK = AgentSubKindsRepo(DB.engine)
CHAT = ChatRepo(DB.engine)