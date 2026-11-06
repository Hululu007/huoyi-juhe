import 'source_registry.dart';

/// 内置导入站种子：随包发布的 py / 阅读 JSON 站。
///
/// 模型走现有导入模型（pyImport / legadoImport），不造新客户端类型：
/// 文件随包发在 assets/builtin_sites/，首启从 asset 拷到导入目录后
/// 按正常导入条目登记（builtin=true，id 稳定为 `seed_<seedId>`）。
/// 用户在站源管理删掉后记墓碑，不再复活（见 SourceRegistry 的
/// _deletedSeeds）。验不过的站不进这张表：柚子短剧本轮未进——
/// 分类/详情/搜索都通，但取流清单两次抓取一次 200、一次连接被重置，
/// 与此前 403 凭证过期是同一类不稳定，未达写进核心的稳定线。
class BuiltinImportedSeed {
  const BuiltinImportedSeed({
    required this.seedId,
    required this.asset,
    required this.fileName,
    required this.name,
    required this.kind,
  });

  final String seedId;
  final String asset;
  final String fileName;
  final String name;
  final SourceKind kind;
}

const builtinImportedSeeds = [
  BuiltinImportedSeed(
    seedId: '91sanji',
    asset: 'assets/builtin_sites/91sanji.py',
    fileName: '91sanji.py',
    name: '🔞91三级',
    kind: SourceKind.pyImport,
  ),
  BuiltinImportedSeed(
    seedId: 'xandaskday',
    asset: 'assets/builtin_sites/xandaskday.py',
    fileName: 'xandaskday.py',
    name: '🔞AI不用钱',
    kind: SourceKind.pyImport,
  ),
  BuiltinImportedSeed(
    seedId: 'aiwu',
    asset: 'assets/builtin_sites/aiwu.py',
    fileName: 'aiwu.py',
    name: '🔞AI污短剧',
    kind: SourceKind.pyImport,
  ),
  BuiltinImportedSeed(
    seedId: '91crdjai',
    asset: 'assets/builtin_sites/91crdjai.py',
    fileName: '91crdjai.py',
    name: '🔞91成人短剧',
    kind: SourceKind.pyImport,
  ),
  BuiltinImportedSeed(
    seedId: 'dabaitu_video',
    asset: 'assets/builtin_sites/dabaitu_video.json',
    fileName: 'dabaitu_video.json',
    name: '🔞大白兔漫社·短剧',
    kind: SourceKind.legadoImport,
  ),
  BuiltinImportedSeed(
    seedId: 'huangguomanju',
    asset: 'assets/builtin_sites/huangguomanju.py',
    fileName: 'huangguomanju.py',
    name: '🔞黄果漫剧',
    kind: SourceKind.pyImport,
  ),
];
