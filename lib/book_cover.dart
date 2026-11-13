import 'package:flutter/material.dart';

class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.title,
    required this.author,
    this.thumbnail = false,
  });

  final String title, author;
  final bool thumbnail;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '《$title》封面',
    image: true,
    child: ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(thumbnail ? 8 : 14),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: LayoutBuilder(
            builder: (context, size) => Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  'assets/memoir-cover.jpg',
                  fit: BoxFit.cover,
                  cacheWidth: thumbnail ? 300 : null,
                  excludeFromSemantics: true,
                ),
                Positioned(
                  left: size.maxWidth * .24,
                  right: size.maxWidth * .25,
                  top: size.maxHeight * .25,
                  bottom: size.maxHeight * .33,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: size.maxWidth * .51,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: thumbnail ? 3 : 5,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: 'Songti SC',
                              fontFamilyFallback: const ['Georgia'],
                              fontSize: thumbnail ? 10 : 28,
                              height: 1.25,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xff352e24),
                            ),
                          ),
                          SizedBox(height: thumbnail ? 4 : 12),
                          Container(
                            width: thumbnail ? 10 : 28,
                            height: 1,
                            color: const Color(0xff9a7845),
                          ),
                          SizedBox(height: thumbnail ? 4 : 10),
                          Text(
                            author,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: thumbnail ? 7 : 15,
                              color: const Color(0xff534637),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
