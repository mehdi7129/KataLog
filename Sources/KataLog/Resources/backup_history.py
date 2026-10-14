"""Local receipt of a successfully verified backup; never a claim of live availability."""
from datetime import datetime, timezone
import json
from pathlib import Path
import re

from local_files import atomic_json, require_local_source

RECEIPT_NAME = 'last-backup.json'
MAX_RECEIPT_BYTES = 16 * 1024 * 1024


def record_verified_backup(library, archive, manifest):
    """Called only after publication or a committed restore. A receipt is ancillary."""
    receipt = {
        'schemaVersion': 1,
        'createdAt': manifest.get('createdAt', ''),
        'verifiedAt': datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
        'archivePath': str(Path(archive).resolve()),
        'includeUlog': bool(manifest.get('includeUlog')),
        'logIDs': sorted({source['logID'] for source in manifest.get('sources', [])}),
        'archivedLogCount': sum(bool(source.get('archivePath')) for source in manifest.get('sources', [])),
        'missingSourceCount': manifest.get('missingSourceCount', 0),
    }
    try:
        if not receipt['createdAt']:
            raise ValueError('Date de création absente.')
        target = Path(library) / RECEIPT_NAME
        if target.is_symlink():
            raise ValueError('Historique de sauvegarde lié symboliquement.')
        atomic_json(target, receipt, separators=(',', ':'), prefix='.last-backup-')
    except (OSError, ValueError):
        return 'La sauvegarde est vérifiée, mais sa date n’a pas pu être enregistrée dans la bibliothèque.'
    return None


def backup_status(library, database):
    path = Path(library) / RECEIPT_NAME
    if not path.exists() and not path.is_symlink():
        return None, None
    try:
        if path.is_symlink() or require_local_source(path).st_size > MAX_RECEIPT_BYTES:
            raise ValueError('Historique non lisible.')
        receipt = json.loads(path.read_bytes())
        if not isinstance(receipt, dict) or receipt.get('schemaVersion') != 1:
            raise ValueError('Version inconnue.')
        identities = receipt.get('logIDs')
        if not isinstance(identities, list) or not all(isinstance(value, str) and re.fullmatch(r'[a-f0-9]{64}', value) for value in identities):
            raise ValueError('Identités invalides.')
        for key in ('createdAt', 'verifiedAt'):
            if not isinstance(receipt.get(key), str) or datetime.fromisoformat(receipt[key].replace('Z', '+00:00')).tzinfo is None:
                raise ValueError('Date invalide.')
        if not isinstance(receipt.get('archivePath'), str) or type(receipt.get('includeUlog')) is not bool:
            raise ValueError('Couverture invalide.')
        for key in ('archivedLogCount', 'missingSourceCount'):
            if type(receipt.get(key)) is not int or receipt[key] < 0 or receipt[key] > len(identities):
                raise ValueError('Compteur invalide.')
        backed_up = set(identities)
        # Compare identities, not totals: deleting one log and adding another
        # must not conceal the newly imported content. No source file is read.
        new_count = sum(row[0] not in backed_up for row in database.execute('SELECT id FROM logs'))
        return {key: value for key, value in receipt.items() if key != 'logIDs'} | {
            'logCount': len(backed_up), 'newLogCount': new_count,
        }, None
    except (OSError, ValueError, TypeError):
        return None, 'La dernière sauvegarde ne peut pas être déterminée : son historique local est illisible.'
