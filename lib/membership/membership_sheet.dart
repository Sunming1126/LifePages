import 'package:flutter/material.dart';
import '../legal_urls.dart';

import '../book_cover.dart';

const _membershipPaper = Color(0xfffcf8ed);
const _membershipAccent = Color(0xff884c2b);

Future<void> showMembership(BuildContext context) => Navigator.of(
  context,
).push<void>(MaterialPageRoute(builder: (_) => const _MembershipPage()));

enum _Plan {
  monthly('月卡', '按月订阅', '1 个月'),
  yearly('年卡', '按年订阅', '12 个月');

  const _Plan(this.label, this.cadence, this.duration);
  final String label, cadence, duration;
}

class _MembershipPage extends StatefulWidget {
  const _MembershipPage();

  @override
  State<_MembershipPage> createState() => _MembershipPageState();
}

class _MembershipPageState extends State<_MembershipPage> {
  var _plan = _Plan.monthly;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: _membershipPaper,
      appBar: AppBar(
        backgroundColor: _membershipPaper,
        surfaceTintColor: Colors.transparent,
        title: const Text('LifePages 会员'),
        actions: const [
          TextButton(onPressed: null, child: Text('恢复购买')),
          SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '把家人的故事，留成一本书。',
                        style: text.headlineMedium?.copyWith(
                          fontFamily: 'Songti SC',
                          fontFamilyFallback: const ['Georgia'],
                          fontWeight: FontWeight.w700,
                          height: 1.28,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text('AI 引导讲述、整理成文，支持 PDF 留存。'),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Transform.rotate(
                  angle: .10,
                  child: const SizedBox(
                    width: 82,
                    child: BookCover(
                      title: '一生的故事',
                      author: 'LifePages',
                      thumbnail: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 26),
            Text(
              '选择会员方案',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final plan in _Plan.values) ...[
                  if (plan != _Plan.values.first) const SizedBox(width: 10),
                  Expanded(
                    child: _PlanCard(
                      plan: plan,
                      selected: plan == _plan,
                      onTap: () => setState(() => _plan = plan),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xfff1e9d9),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_plan.label}方案',
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text('订阅周期 ${_plan.duration}'),
                  ],
                ),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton(
                  onPressed: () =>
                      AppLegalUrls.open(context, AppLegalUrls.privacy),
                  child: const Text('隐私政策'),
                ),
                TextButton(
                  onPressed: () =>
                      AppLegalUrls.open(context, AppLegalUrls.terms),
                  child: const Text('使用条款'),
                ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: _membershipPaper,
          border: Border(top: BorderSide(color: Color(0xffe6ddca))),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const FilledButton(onPressed: null, child: Text('订阅暂未开放')),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    '继续免费记录',
                    style: TextStyle(color: _membershipAccent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.selected,
    required this.onTap,
  });
  final _Plan plan;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: selected ? const Color(0xfff5e3cb) : const Color(0xfffffcf6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? _membershipAccent : const Color(0xffe6ddca),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      plan.label,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected
                        ? _membershipAccent
                        : const Color(0xff958979),
                    size: 20,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(plan.cadence),
            ],
          ),
        ),
      ),
    ),
  );
}
